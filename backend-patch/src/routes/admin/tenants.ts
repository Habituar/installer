import { Router, Request, Response, NextFunction } from 'express';
import bcrypt from 'bcryptjs';
import crypto from 'crypto';
import { registrarAuditoria } from '../../services/auditoriaService.js';
import { z } from 'zod';
import { gerarChaveLicenca, salvarLicenca, validarChaveLicenca } from '../../services/licenca.js';
import { Cliente, Usuario } from '../../entities/index.js';
import { invalidarCache } from '../../middlewares/verificarLicenca.js';
import { db } from '../../lib/db.js';
import { atualizar } from '../../lib/dbUtils.js';

export const adminTenantsRouter = Router();

function sanitizeUsuario(u: any) {
  const { senhaHash, ...semSenha } = u;
  return semSenha;
}

/**
 * Gera uma senha aleatória segura (letras, números e símbolos) para
 * comunicação manual ao cliente pelo Diretor.
 */
function gerarSenhaAleatoria(tamanho = 12): string {
  const charset = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%';
  const bytes = crypto.randomBytes(tamanho);
  let senha = '';
  for (let i = 0; i < tamanho; i++) {
    senha += charset[bytes[i] % charset.length];
  }
  return senha;
}

/**
 * Retorna o acesso mais recente entre os usuários de um tenant.
 * Calculado em memória (em vez de ORDER BY no banco) para não depender da
 * ordenação de valores nulos específica de cada banco.
 */
async function buscarUltimoAcessoTenant(db: any, clienteId: string): Promise<Date | null> {
  const usuarios = await db.usuario.find({ where: { clienteId } });
  let maisRecente: Date | null = null;
  for (const u of usuarios) {
    if (!u.ultimoAcesso) continue;
    const data = new Date(u.ultimoAcesso);
    if (!maisRecente || data > maisRecente) maisRecente = data;
  }
  return maisRecente;
}

async function buscarTenantOu404(db: any, id: string, res: Response) {
  const tenant = await db.cliente.findOne({ where: { id } });
  if (!tenant) {
    res.status(404).json({
      sucesso: false,
      mensagem: 'Cliente não encontrado',
      codigo: 'CLIENTE_NAO_ENCONTRADO',
    });
    return null;
  }
  return tenant;
}

const criarTenantSchema = z.object({
  nome: z.string().min(2, 'Nome obrigatório'),
  cnpj: z.string().min(14, 'CNPJ obrigatório'),
  tipo: z.enum(['saas', 'on-premise']).default('saas'),
  plano: z.string().min(1).max(100).default('basico'),
  nomeAdmin: z.string().min(2, 'Nome do administrador obrigatório'),
  emailAdmin: z.string().email('E-mail do administrador inválido'),
  loginAdmin: z.string().min(3, 'Login do administrador obrigatório'),
  senhaAdmin: z.string().min(6, 'Senha deve ter ao menos 6 caracteres'),
  observacoes: z.string().optional(),
});

/**
 * POST /api/super/tenants
 * Cria novo tenant e seu usuário Administrador.
 */
adminTenantsRouter.post('/', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const dados = criarTenantSchema.parse(req.body);

    const cnpjLimpo = dados.cnpj.replace(/\D/g, '');
    const existente = await db.cliente.findOne({ where: { cnpj: cnpjLimpo } });
    if (existente) {
      return res.status(409).json({ sucesso: false, mensagem: 'Já existe um tenant com esse CNPJ.' });
    }

    const senhaHash = await bcrypt.hash(dados.senhaAdmin, 12);

    // Cliente e administrador são criados na mesma transação (tudo ou nada)
    const tenant = await db.manager.transaction(async (m) => {
      const novoCliente = await m.save(
        m.create(Cliente, {
          nome: dados.nome,
          cnpj: cnpjLimpo,
          tipo: dados.tipo,
          plano: dados.plano,
          ativo: true,
          licencaValida: true,
          observacoes: dados.observacoes,
        })
      );
      const admin = await m.save(
        m.create(Usuario, {
          clienteId: novoCliente.id,
          nome: dados.nomeAdmin,
          email: dados.emailAdmin.toLowerCase().trim(),
          login: dados.loginAdmin.trim(),
          senhaHash,
          perfil: 'Administrador',
          ativo: true,
          trocarSenhaNoLogin: true,
        })
      );
      return {
        ...novoCliente,
        usuarios: [{ id: admin.id, nome: admin.nome, email: admin.email, login: admin.login, perfil: admin.perfil }],
      };
    });

    res.status(201).json({ sucesso: true, tenant });
  } catch (error) {
    next(error);
  }
});

/**
 * GET /api/super/tenants
 * Lista tenants com estatísticas, filtros e paginação
 */
adminTenantsRouter.get('/', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { ativo, plano, busca } = req.query;

    const where: any = {};
    if (ativo === 'true') where.ativo = true;
    else if (ativo === 'false') where.ativo = false;
    if (plano) where.plano = String(plano);

    let tenants = await db.cliente.find({ where, order: { criadoEm: 'DESC' } });

    if (busca) {
      const termo = String(busca).toLowerCase();
      const termoNumerico = termo.replace(/\D/g, '');
      tenants = tenants.filter((t: any) => {
        const nomeMatch = String(t.nome || '').toLowerCase().includes(termo);
        const cnpjMatch = termoNumerico ? String(t.cnpj || '').includes(termoNumerico) : false;
        return nomeMatch || cnpjMatch;
      });
    }

    const total = tenants.length;
    const pagina = Math.max(1, parseInt(String(req.query.pagina || '1'), 10) || 1);
    const limite = Math.max(1, parseInt(String(req.query.limite || '20'), 10) || 20);
    const skip = (pagina - 1) * limite;
    const pageItems = tenants.slice(skip, skip + limite);

    const tenantsComEstatisticas = await Promise.all(
      pageItems.map(async (t: any) => {
        const [totalUsuarios, totalEmpresas, totalLotes, ultimoAcesso] = await Promise.all([
          db.usuario.count({ where: { clienteId: t.id } }),
          db.empresa.count({ where: { tenantId: t.id } }),
          db.lote.count({ where: { tenantId: t.id } }),
          buscarUltimoAcessoTenant(db, t.id),
        ]);

        return {
          id: t.id,
          nome: t.nome,
          cnpj: t.cnpj,
          plano: t.plano,
          ativo: t.ativo,
          modoLeitura: t.modoLeitura,
          licencaValida: t.licencaValida,
          licencaVencEm: t.licencaVencEm,
          observacoes: t.observacoes,
          criadoEm: t.criadoEm,
          atualizadoEm: t.atualizadoEm,
          totalUsuarios,
          totalEmpresas,
          totalLotes,
          ultimoAcesso,
        };
      })
    );

    res.json({
      sucesso: true,
      total,
      pagina,
      limite,
      totalPaginas: Math.max(1, Math.ceil(total / limite)),
      tenants: tenantsComEstatisticas,
    });
  } catch (error) {
    next(error);
  }
});

/**
 * GET /api/super/tenants/:id
 * Detalhe completo do tenant
 */
adminTenantsRouter.get('/:id', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const tenant = await buscarTenantOu404(db, req.params.id, res);
    if (!tenant) return;

    const [usuarios, empresas, ultimosLotes] = await Promise.all([
      db.usuario.find({ where: { clienteId: tenant.id }, order: { nome: 'ASC' } }),
      db.empresa.find({ where: { tenantId: tenant.id }, order: { razaoSocial: 'ASC' } }),
      db.lote.find({ where: { tenantId: tenant.id }, order: { criadoEm: 'DESC' }, take: 5 }),
    ]);

    res.json({
      sucesso: true,
      tenant: {
        ...tenant,
        usuarios: usuarios.map(sanitizeUsuario),
        empresas,
        ultimosLotes,
      },
    });
  } catch (error) {
    next(error);
  }
});

/**
 * PUT /api/super/tenants/:id/ativar
 */
adminTenantsRouter.put('/:id/ativar', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const tenant = await buscarTenantOu404(db, req.params.id, res);
    if (!tenant) return;

    const atualizado = await atualizar(db.cliente, tenant.id, { ativo: true, licencaValida: true });

    res.json({ sucesso: true, mensagem: 'Cliente ativado com sucesso', tenant: atualizado });
  } catch (error) {
    next(error);
  }
});

/**
 * PUT /api/super/tenants/:id/suspender
 * Cliente ainda acessa a plataforma, mas não pode operar (bloqueado pelo checkModoLeitura)
 */
adminTenantsRouter.put('/:id/suspender', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const tenant = await buscarTenantOu404(db, req.params.id, res);
    if (!tenant) return;

    const atualizado = await atualizar(db.cliente, tenant.id, { licencaValida: false });

    res.json({ sucesso: true, mensagem: 'Cliente suspenso com sucesso', tenant: atualizado });
  } catch (error) {
    next(error);
  }
});

/**
 * PUT /api/super/tenants/:id/cancelar
 * Bloqueia totalmente o acesso do tenant
 */
adminTenantsRouter.put('/:id/cancelar', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const tenant = await buscarTenantOu404(db, req.params.id, res);
    if (!tenant) return;

    const atualizado = await atualizar(db.cliente, tenant.id, { ativo: false });

    res.json({ sucesso: true, mensagem: 'Cliente cancelado com sucesso', tenant: atualizado });
  } catch (error) {
    next(error);
  }
});

const modoLeituraSchema = z.object({
  ativar: z.boolean(),
});

/**
 * PUT /api/super/tenants/:id/modo-leitura
 */
adminTenantsRouter.put('/:id/modo-leitura', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const dados = modoLeituraSchema.parse(req.body);
    const tenant = await buscarTenantOu404(db, req.params.id, res);
    if (!tenant) return;

    const atualizado = await atualizar(db.cliente, tenant.id, { modoLeitura: dados.ativar });

    res.json({
      sucesso: true,
      mensagem: dados.ativar
        ? 'Modo somente leitura ativado para o tenant'
        : 'Modo somente leitura desativado para o tenant',
      tenant: atualizado,
    });
  } catch (error) {
    next(error);
  }
});

const planoSchema = z.object({
  plano: z.string().min(1).max(100),
  licencaVencEm: z.string().optional(),
});

/**
 * PUT /api/super/tenants/:id/plano
 */
adminTenantsRouter.put('/:id/plano', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const dados = planoSchema.parse(req.body);
    const tenant = await buscarTenantOu404(db, req.params.id, res);
    if (!tenant) return;

    let licencaVencEm: Date | undefined;
    if (dados.licencaVencEm) {
      const data = new Date(dados.licencaVencEm);
      if (isNaN(data.getTime())) {
        return res.status(400).json({
          sucesso: false,
          mensagem: 'Data de vencimento da licença inválida',
          codigo: 'DATA_INVALIDA',
        });
      }
      licencaVencEm = data;
    }

    const atualizado = await atualizar(db.cliente, tenant.id, {
        plano: dados.plano,
        ...(licencaVencEm ? { licencaVencEm } : {}),
      });

    res.json({ sucesso: true, mensagem: 'Plano do tenant atualizado com sucesso', tenant: atualizado });
  } catch (error) {
    next(error);
  }
});

const observacoesSchema = z.object({
  observacoes: z.string(),
});

/**
 * PUT /api/super/tenants/:id/observacoes
 */
adminTenantsRouter.put('/:id/observacoes', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const dados = observacoesSchema.parse(req.body);
    const tenant = await buscarTenantOu404(db, req.params.id, res);
    if (!tenant) return;

    const atualizado = await atualizar(db.cliente, tenant.id, { observacoes: dados.observacoes });

    res.json({ sucesso: true, mensagem: 'Observações internas atualizadas com sucesso', tenant: atualizado });
  } catch (error) {
    next(error);
  }
});

/**
 * POST /api/super/tenants/:id/reset-senha-admin
 * Gera uma nova senha aleatória para o usuário Administrador do tenant.
 */
adminTenantsRouter.post('/:id/reset-senha-admin', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const tenant = await buscarTenantOu404(db, req.params.id, res);
    if (!tenant) return;

    const usuarioAdmin = await db.usuario.findOne({
      where: { clienteId: tenant.id, perfil: 'Administrador' },
    });

    if (!usuarioAdmin) {
      return res.status(404).json({
        sucesso: false,
        mensagem: 'Nenhum usuário administrador encontrado para este tenant',
        codigo: 'ADMIN_NAO_ENCONTRADO',
      });
    }

    const novaSenha = gerarSenhaAleatoria();
    const salt = await bcrypt.genSalt(10);
    const senhaHash = await bcrypt.hash(novaSenha, salt);

    await db.usuario.update({ id: usuarioAdmin.id }, { senhaHash, trocarSenhaNoLogin: true });

    await registrarAuditoria({
      tenantId: tenant.id,
      usuarioId: req.userId!,
      acao: 'reset_senha_admin',
      recurso: 'usuario',
      recursoId: usuarioAdmin.id,
      detalhes: { login: usuarioAdmin.login, executadoPeloPainelAdmin: true },
      ip: req.ip,
    });

    res.json({
      sucesso: true,
      mensagem: 'Senha do administrador redefinida com sucesso. Comunique a nova senha ao cliente com segurança.',
      novaSenha,
      usuario: { id: usuarioAdmin.id, login: usuarioAdmin.login, email: usuarioAdmin.email },
    });
  } catch (error) {
    next(error);
  }
});

/**
 * GET /api/super/tenants/:id/licenca
 */
adminTenantsRouter.get('/:id/licenca', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const licenca = await db.licenca.findOne({
      where: { clienteId: req.params.id },
      relations: { plano: true },
    });
    if (!licenca) return res.json({ sucesso: true, licenca: null });
    const r = licenca.chave ? validarChaveLicenca(licenca.chave) : null;
    res.json({ sucesso: true, licenca: { ...licenca, diasRestantes: r?.diasRestantes ?? null } });
  } catch (e) { next(e); }
});

const licencaSchema = z.object({
  planoId: z.string().optional().nullable(),
  tipo: z.enum(['saas', 'on-premise']),
  maxEmpresas: z.number().int().positive().nullable().optional(),
  maxUsuarios: z.number().int().positive().nullable().optional(),
  maxDeclarados: z.number().int().positive().nullable().optional(),
  maxContas: z.number().int().positive().nullable().optional(),
  maxLotesTotal: z.number().int().positive().nullable().optional(),
  ambientes: z.enum(['producao', 'homologacao', 'ambos']).default('ambos'),
  validaAte: z.string().refine((v) => !isNaN(Date.parse(v)), 'validaAte inválida'),
  diasGraca: z.number().int().min(0).default(0),
});

/**
 * POST /api/super/tenants/:id/licencas — Gerar nova licença
 */
adminTenantsRouter.post('/:id/licencas', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const clienteId = req.params.id;
    const dados = licencaSchema.parse(req.body);

    // Se planoId fornecido, busca limites do plano
    let limites = {
      maxEmpresas: dados.maxEmpresas ?? null,
      maxUsuarios: dados.maxUsuarios ?? null,
      maxDeclarados: dados.maxDeclarados ?? null,
      maxContas: dados.maxContas ?? null,
      maxLotesTotal: dados.maxLotesTotal ?? null,
    };
    if (dados.planoId) {
      const plano = await db.planoSistema.findOne({ where: { id: dados.planoId } });
      if (plano) {
        limites = {
          maxEmpresas: dados.maxEmpresas ?? plano.maxEmpresas,
          maxUsuarios: dados.maxUsuarios ?? plano.maxUsuarios,
          maxDeclarados: dados.maxDeclarados ?? plano.maxDeclarados,
          maxContas: dados.maxContas ?? plano.maxContas,
          maxLotesTotal: dados.maxLotesTotal ?? plano.maxLotesTotal,
        };
      }
    }

    // A licença fica vinculada ao CNPJ do cliente (lança EntityNotFoundError → 404 se o cliente não existir)
    const cliente = await db.cliente.findOneByOrFail({ id: clienteId });

    // Descobre versão atual
    const existente = await db.licenca.findOne({ where: { clienteId } });
    const versao = (existente?.versao ?? 0) + 1;
    const validaAte = new Date(dados.validaAte);
    const emitidaEm = new Date();

    const chave = gerarChaveLicenca({
      clienteId, cnpj: cliente.cnpj, tipo: dados.tipo, versao, ...limites,
      ambientes: dados.ambientes, emitidaEm, validaAte, diasGraca: dados.diasGraca,
    });

    const campos = {
      planoId: dados.planoId ?? null, tipo: dados.tipo, chave, versao,
      ...limites, ambientes: dados.ambientes, emitidaEm, validaAte, diasGraca: dados.diasGraca, status: 'ativa',
    };
    const licenca = await salvarLicenca(clienteId, campos);

    invalidarCache(clienteId);
    res.status(201).json({ sucesso: true, licenca, chave });
  } catch (e) { next(e); }
});

/**
 * PUT /api/super/tenants/:id/licenca/cancelar
 */
adminTenantsRouter.put('/:id/licenca/cancelar', async (req: Request, res: Response, next: NextFunction) => {
  try {
    // Lança EntityNotFoundError (→ 404) quando o cliente não tem licença
    const atual = await db.licenca.findOneByOrFail({ clienteId: req.params.id });
    const licenca = await atualizar(db.licenca, atual.id, { status: 'cancelada' });
    invalidarCache(req.params.id);
    res.json({ sucesso: true, licenca });
  } catch (e) { next(e); }
});
