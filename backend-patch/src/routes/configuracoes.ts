import { Router, Request, Response, NextFunction } from 'express';
import { z } from 'zod';
import { requirePerfil } from '../middlewares/auth.js';
import { escopoMiddleware } from '../middlewares/escopo.js';
import { databaseMiddleware } from '../middlewares/database.js';
import { invalidarCache } from '../middlewares/verificarLicenca.js';
import { salvarLicenca, validarChaveLicenca } from '../services/licenca.js';
import { db } from '../lib/db.js';
import { reposDe } from '../lib/dbUtils.js';
import { limparCnpj } from '../utils/cnpj.js';

export const configuracoesRouter = Router();

/**
 * GET /api/configuracoes/uso-atual
 * Uso atual, contado com os mesmos critérios de verificarLimites (services/licenca.ts): empresas
 * ativas, usuários ativos e os demais recursos sem filtro de situação. Mistura master (Usuario,
 * por clienteId) com TENANT_ENTITIES (Empresa/Declarado/Conta/Lote, por escopoId — na BaseDados
 * selecionada) — por isso escopoMiddleware/databaseMiddleware são aplicados só aqui, não no
 * router inteiro (PUT /licenca precisa funcionar sem base selecionada — ver index.ts).
 */
configuracoesRouter.get('/uso-atual', escopoMiddleware, databaseMiddleware, async (req: Request, res: Response, next: NextFunction) => {
  try {
    const clienteId = req.clienteId!;
    const escopoId = req.escopoId!;
    const r = reposDe(req.ds);

    const [empresas, usuarios, declarados, contas, lotesTotal] = await Promise.all([
      r.empresa.count({ where: { tenantId: escopoId, situacao: 'Ativa' } }),
      db.usuario.count({ where: { clienteId, ativo: true } }), // Usuario é master
      r.declarado.count({ where: { tenantId: escopoId } }),
      r.conta.count({ where: { tenantId: escopoId } }),
      r.lote.count({ where: { tenantId: escopoId } }),
    ]);

    res.json({ empresas, usuarios, declarados, contas, lotesTotal });
  } catch (error) {
    next(error);
  }
});

const colarLicencaSchema = z.object({
  chave: z.string().min(1, 'Chave de licença é obrigatória'),
});

/**
 * PUT /api/configuracoes/licenca
 * Cliente (on-premise) cola a chave de licença emitida pelo painel master.
 * Requer JWT de cliente com perfil Administrador.
 */
configuracoesRouter.put('/licenca', requirePerfil('Administrador'), async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { chave } = colarLicencaSchema.parse(req.body);
    const clienteId = req.clienteId!;

    const resultado = validarChaveLicenca(chave.trim());
    // A licença é vinculada ao CNPJ do cliente. Chaves antigas (sem cnpj) continuam presas ao clienteId.
    const cliente = await db.cliente.findOneByOrFail({ id: clienteId });
    const pCnpj = resultado.payload?.cnpj as string | undefined;
    const pertence = pCnpj
      ? limparCnpj(pCnpj) === limparCnpj(cliente.cnpj)
      : resultado.payload?.clienteId === clienteId;
    if (!resultado.valida || !pertence) {
      return res.status(400).json({
        sucesso: false,
        mensagem: resultado.valida ? 'Esta chave pertence a outra instituição.' : resultado.erro,
        codigo: 'LICENCA_INVALIDA',
      });
    }

    const p = resultado.payload;
    const limites = p.limites || {};
    const campos = {
      tipo: p.tipo,
      chave: chave.trim(),
      versao: p.versao,
      maxEmpresas: limites.maxEmpresas ?? null,
      maxUsuarios: limites.maxUsuarios ?? null,
      maxDeclarados: limites.maxDeclarados ?? null,
      maxContas: limites.maxContas ?? null,
      maxLotesTotal: limites.maxLotesTotal ?? null,
      ambientes: p.ambientes || limites.ambientes || 'ambos',
      emitidaEm: new Date(p.emitidaEm),
      validaAte: new Date(p.validaAte),
      diasGraca: p.diasGraca ?? 0,
      status: 'ativa',
    };

    await salvarLicenca(clienteId, campos);
    invalidarCache(clienteId);

    res.json({
      sucesso: true,
      licenca: {
        diasRestantes: resultado.diasRestantes,
        validaAte: campos.validaAte,
        limites,
      },
    });
  } catch (error) { next(error); }
});
