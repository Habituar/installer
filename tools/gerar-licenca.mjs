// Gera uma chave de licença on-premise para um CNPJ, direto no seu computador (sem painel, sem Railway).
//
//   node installer\tools\gerar-licenca.mjs --cnpj 11.222.333/0001-81 --dias 365
//
// Opções (todas opcionais, exceto --cnpj):
//   --dias 365            validade a partir de hoje (padrão 365)
//   --empresas N  --usuarios N  --declarados N  --contas N  --lotes N     limites (sem o parâmetro = ilimitado)
//   --ambientes ambos|producao|homologacao       (padrão ambos)
//   --graca N             dias de tolerância após o vencimento (padrão 0)
//   --chave caminho.pem   chave PRIVADA (padrão: chaves-licenca\license-private.pem, criada por gerar-chaves-licenca.mjs)
//
// Sem dependências: usa só o Node. A chave impressa é o que o cliente cola em Configurações → Licença.
import { createPrivateKey, sign } from 'node:crypto';
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

function arg(nome, padrao) {
  const i = process.argv.indexOf(`--${nome}`);
  return i > -1 && process.argv[i + 1] !== undefined ? process.argv[i + 1] : padrao;
}
function falha(msg) { console.error(`Erro: ${msg}`); process.exit(1); }
function limite(nome) {
  const v = arg(nome);
  if (v === undefined) return null;
  const n = Number(v);
  if (!Number.isInteger(n) || n <= 0) falha(`--${nome} precisa ser um número inteiro positivo.`);
  return n;
}

// CNPJ alfanumérico (IN RFB 2.229/2024): valor do caractere = código ASCII - 48
function dv(s, n) {
  let soma = 0, peso = 2;
  for (let i = n; i >= 1; i--) {
    soma += (s.charCodeAt(i - 1) - 48) * peso;
    peso = peso === 9 ? 2 : peso + 1;
  }
  const r = soma % 11;
  return r < 2 ? 0 : 11 - r;
}
function cnpjValido(s) {
  return /^[A-Z0-9]{12}\d{2}$/.test(s) && !/^(.)\1+$/.test(s) && dv(s, 12) === +s[12] && dv(s, 13) === +s[13];
}

const cnpj = (arg('cnpj') || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
if (!cnpj) falha('informe o CNPJ: --cnpj 11.222.333/0001-81');
if (!cnpjValido(cnpj)) falha(`CNPJ inválido (${cnpj}). A licença só funciona para o CNPJ exato da instalação.`);

const dias = Number(arg('dias', '365'));
if (!Number.isInteger(dias) || dias <= 0) falha('--dias precisa ser um número inteiro positivo.');
const graca = Number(arg('graca', '0'));
if (!Number.isInteger(graca) || graca < 0) falha('--graca precisa ser um número inteiro (0 ou mais).');
const ambientes = arg('ambientes', 'ambos');
if (!['ambos', 'producao', 'homologacao'].includes(ambientes)) falha('--ambientes: ambos, producao ou homologacao.');

const aqui = dirname(fileURLToPath(import.meta.url));
const caminhoChave = arg('chave', join(aqui, '..', '..', 'chaves-licenca', 'license-private.pem'));
if (!existsSync(caminhoChave)) falha(`chave privada não encontrada em ${caminhoChave}. Rode antes: node installer\\tools\\gerar-chaves-licenca.mjs`);
const pem = readFileSync(caminhoChave, 'utf8');
if (!pem.includes('PRIVATE KEY')) falha(`${caminhoChave} não é uma chave privada.`);

const agora = new Date();
const validaAte = new Date(agora.getTime() + dias * 86400_000);
const nowSec = Math.floor(agora.getTime() / 1000);
const expSec = Math.floor((validaAte.getTime() + graca * 86400_000) / 1000);

// Mesmo formato de gerarChaveLicenca() do backend (services/licenca.ts)
const payload = {
  clienteId: `on-premise-${cnpj}`,
  cnpj,
  tipo: 'on-premise',
  versao: 1,
  limites: {
    maxEmpresas: limite('empresas'),
    maxUsuarios: limite('usuarios'),
    maxDeclarados: limite('declarados'),
    maxContas: limite('contas'),
    maxLotesTotal: limite('lotes'),
  },
  ambientes,
  emitidaEm: agora.toISOString(),
  validaAte: validaAte.toISOString(),
  diasGraca: graca,
  iss: 'efinanceira-master',
  iat: nowSec,
  exp: expSec,
};

const b64u = (o) => Buffer.from(typeof o === 'string' ? o : JSON.stringify(o)).toString('base64url');
const cabecalhoPayload = `${b64u({ alg: 'RS256', typ: 'JWT' })}.${b64u(payload)}`;
const assinatura = sign('RSA-SHA256', Buffer.from(cabecalhoPayload), createPrivateKey(pem)).toString('base64url');
const chave = `${cabecalhoPayload}.${assinatura}`;

console.log(`
Licença gerada.
  CNPJ:      ${cnpj}
  Válida até: ${validaAte.toLocaleDateString('pt-BR')}${graca ? ` (+${graca} dias de tolerância)` : ''}
  Ambientes: ${ambientes}
  Limites:   empresas=${payload.limites.maxEmpresas ?? '∞'} usuários=${payload.limites.maxUsuarios ?? '∞'} declarados=${payload.limites.maxDeclarados ?? '∞'} contas=${payload.limites.maxContas ?? '∞'} lotes=${payload.limites.maxLotesTotal ?? '∞'}

Chave (copie a linha inteira e cole em Configurações → Licença):

${chave}
`);
