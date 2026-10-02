import jwt from 'jsonwebtoken';
import { QueryDeepPartialEntity } from 'typeorm';
import AppDataSource from '../lib/dataSource.js';
import { Licenca } from '../entities/index.js';

/**
 * Assinatura da licença:
 *  - Preferencial (RS256): o painel master assina com LICENSE_PRIVATE_KEY_B64 (chave privada, só no master);
 *    as instalações on-premise levam apenas LICENSE_PUBLIC_KEY_B64, que valida mas não consegue gerar licenças.
 *  - Legado (HS256): LICENSE_SECRET, segredo igual nos dois lados. Continua valendo para chaves já emitidas.
 * As chaves PEM ficam em base64 (uma linha) nas variáveis de ambiente.
 */
function pem(b64: string | undefined): string | undefined {
  return b64 ? Buffer.from(b64, 'base64').toString('utf8') : undefined;
}

export function licencaConfigurada(): boolean {
  return !!(process.env.LICENSE_PUBLIC_KEY_B64 || process.env.LICENSE_SECRET);
}

function assinar(payload: object, expiresIn: number): string {
  const privada = pem(process.env.LICENSE_PRIVATE_KEY_B64);
  if (privada) return jwt.sign(payload, privada, { algorithm: 'RS256', expiresIn });
  const s = process.env.LICENSE_SECRET;
  if (!s) throw new Error('Nenhuma chave para assinar licenças (LICENSE_PRIVATE_KEY_B64 ou LICENSE_SECRET).');
  return jwt.sign(payload, s, { algorithm: 'HS256', expiresIn });
}

function verificar(chave: string): any {
  const publica = pem(process.env.LICENSE_PUBLIC_KEY_B64);
  const s = process.env.LICENSE_SECRET;
  if (!publica && !s) throw new Error('LICENSE_PUBLIC_KEY_B64 (ou LICENSE_SECRET) não definida no ambiente.');
  let erro: any;
  if (publica) {
    try { return jwt.verify(chave, publica, { algorithms: ['RS256'] }); } catch (e) { erro = e; }
  }
  if (s) {
    try { return jwt.verify(chave, s, { algorithms: ['HS256'] }); } catch (e: any) {
      if (!erro || e?.name === 'TokenExpiredError') erro = e;
    }
  }
  throw erro;
}

export function gerarChaveLicenca(payload: {
  clienteId: string;
  cnpj?: string; // a licença fica vinculada ao CNPJ do cliente (on-premise valida por ele)
  tipo: string;
  versao: number;
  maxEmpresas: number | null;
  maxUsuarios: number | null;
  maxDeclarados: number | null;
  maxContas: number | null;
  maxLotesTotal: number | null;
  ambientes: string;
  emitidaEm: Date;
  validaAte: Date;
  diasGraca: number;
}): string {
  const expMs = new Date(payload.validaAte).getTime() + payload.diasGraca * 86400_000;
  const expSec = Math.floor(expMs / 1000);
  const nowSec = Math.floor(Date.now() / 1000);
  return assinar(
    {
      clienteId: payload.clienteId,
      cnpj: payload.cnpj,
      tipo: payload.tipo,
      versao: payload.versao,
      limites: {
        maxEmpresas: payload.maxEmpresas,
        maxUsuarios: payload.maxUsuarios,
        maxDeclarados: payload.maxDeclarados,
        maxContas: payload.maxContas,
        maxLotesTotal: payload.maxLotesTotal,
      },
      ambientes: payload.ambientes,
      emitidaEm: payload.emitidaEm.toISOString(),
      validaAte: payload.validaAte.toISOString(),
      diasGraca: payload.diasGraca,
      iss: 'efinanceira-master',
    },
    expSec - nowSec
  );
}

export function validarChaveLicenca(chave: string): {
  valida: boolean;
  expirada: boolean;
  diasRestantes: number;
  payload: any | null;
  erro?: string;
} {
  try {
    const decoded = verificar(chave) as any;
    const validaAte = new Date(decoded.validaAte);
    const diasRestantes = Math.ceil((validaAte.getTime() - Date.now()) / 86400_000);
    return { valida: true, expirada: diasRestantes < 0, diasRestantes, payload: decoded };
  } catch (err: any) {
    const expirada = err?.name === 'TokenExpiredError';
    return { valida: false, expirada, diasRestantes: 0, payload: null,
      erro: expirada ? 'Licença expirada' : 'Chave de licença inválida' };
  }
}

// Resumo da licença do cliente para login e /me (null = cliente sem licença cadastrada)
export async function obterLicencaStatus(clienteId: string) {
  const licenca = await AppDataSource.getRepository(Licenca).findOneBy({ clienteId });
  if (!licenca) return null;

  const resultado = licenca.chave ? validarChaveLicenca(licenca.chave) : null;
  const diasRestantes = resultado?.diasRestantes ?? Math.ceil((new Date(licenca.validaAte).getTime() - Date.now()) / 86400_000);
  return {
    tipo: licenca.tipo,
    validaAte: licenca.validaAte,
    diasRestantes,
    expirada: resultado?.expirada ?? diasRestantes < 0,
    status: licenca.status,
    limites: resultado?.payload?.limites || null,
    alertaVencimento: diasRestantes >= 0 && diasRestantes <= 10,
  };
}

// Cria ou atualiza a licença do cliente (um registro por cliente) e devolve o registro salvo
export async function salvarLicenca(clienteId: string, campos: QueryDeepPartialEntity<Licenca>): Promise<Licenca> {
  const repo = AppDataSource.getRepository(Licenca);
  const existente = await repo.findOneBy({ clienteId });
  if (existente) {
    await repo.update(existente.id, campos);
    return repo.findOneByOrFail({ id: existente.id });
  }
  return repo.save(repo.create({ clienteId, ...(campos as Partial<Licenca>) }));
}
