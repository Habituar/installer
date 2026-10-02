// Gera o par de chaves (RSA 3072) para assinar e validar licenças do e-Financeira.
//   node installer\tools\gerar-chaves-licenca.mjs
// Rode UMA vez. A chave PRIVADA nunca vai para o instalador nem para o cliente.
import { generateKeyPairSync } from 'node:crypto';
import { mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const aqui = dirname(fileURLToPath(import.meta.url));
const pastaInstalador = join(aqui, '..');
const pastaPrivada = join(pastaInstalador, '..', 'chaves-licenca'); // fora da pasta installer

const destinoPublica = join(pastaInstalador, 'license-public.pem');
if (existsSync(destinoPublica)) {
  console.error(`Já existe ${destinoPublica}. Se gerar outro par, TODAS as licenças já entregues deixam de valer. Apague o arquivo se for isso mesmo que você quer.`);
  process.exit(1);
}

const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 3072 });
const pubPem = publicKey.export({ type: 'spki', format: 'pem' });
const privPem = privateKey.export({ type: 'pkcs8', format: 'pem' });

mkdirSync(pastaPrivada, { recursive: true });
writeFileSync(join(pastaPrivada, 'license-private.pem'), privPem, { mode: 0o600 });
writeFileSync(destinoPublica, pubPem);

const b64 = (s) => Buffer.from(s).toString('base64');
console.log(`
Chaves geradas.

  Chave PÚBLICA (vai no instalador): ${destinoPublica}
  Chave PRIVADA (SECRETA, faça backup): ${join(pastaPrivada, 'license-private.pem')}

Agora cadastre estas duas variáveis no backend do PAINEL MASTER (Railway):

LICENSE_PRIVATE_KEY_B64=${b64(privPem)}

LICENSE_PUBLIC_KEY_B64=${b64(pubPem)}

Mantenha também o LICENSE_SECRET atual lá, para as licenças antigas continuarem valendo.
Nunca coloque a chave privada no instalador, no GitHub ou em e-mail.
`);
