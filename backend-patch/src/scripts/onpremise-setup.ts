import 'dotenv/config';
import 'reflect-metadata';
import bcrypt from 'bcryptjs';
import AppDataSource from '../lib/dataSource.js';
import { Cliente, Usuario } from '../entities/index.js';
import { limparCnpj, validarCnpj } from '../utils/cnpj.js';

/**
 * Setup inicial da instalação on-premise. Chamado pelo instalador (installer/scripts/postinstall.ps1)
 * com as variáveis de ambiente do backend já carregadas:
 *   CLIENTE_NOME, CLIENTE_CNPJ, ADMIN_NOME, ADMIN_EMAIL, ADMIN_SENHA
 *
 * 1. Aplica as migrations (cria as tabelas).
 * 2. Cria o Cliente (com o CNPJ da instituição) e o usuário Administrador.
 * A licença NÃO é criada aqui: no primeiro acesso o sistema responde LICENCA_NAO_ATIVADA e o
 * Administrador cola a chave em Configurações → Licença (a chave precisa ser do mesmo CNPJ).
 *
 * Idempotente: se já existir algum Cliente, não faz nada.
 */
async function main() {
  const { CLIENTE_NOME, CLIENTE_CNPJ, ADMIN_NOME, ADMIN_EMAIL, ADMIN_SENHA } = process.env;
  if (!CLIENTE_NOME || !CLIENTE_CNPJ || !ADMIN_NOME || !ADMIN_EMAIL || !ADMIN_SENHA) {
    throw new Error('Defina CLIENTE_NOME, CLIENTE_CNPJ, ADMIN_NOME, ADMIN_EMAIL e ADMIN_SENHA.');
  }
  const cnpj = limparCnpj(CLIENTE_CNPJ);
  if (!validarCnpj(cnpj)) throw new Error('CNPJ inválido.');
  const email = ADMIN_EMAIL.trim().toLowerCase();
  if (!email.includes('@')) throw new Error('E-mail do administrador inválido.');

  await AppDataSource.initialize();
  try {
    const aplicadas = await AppDataSource.runMigrations();
    console.log(`Migrations aplicadas: ${aplicadas.length}`);

    const clienteRepo = AppDataSource.getRepository(Cliente);
    const usuarioRepo = AppDataSource.getRepository(Usuario);

    if ((await clienteRepo.count()) > 0) {
      console.log('Instalação já configurada: nenhum dado criado.');
      return;
    }

    const cliente = await clienteRepo.save(
      clienteRepo.create({ nome: CLIENTE_NOME.trim(), cnpj, plano: 'enterprise', ativo: true, tipo: 'on-premise' })
    );

    await usuarioRepo.save(
      usuarioRepo.create({
        clienteId: cliente.id,
        login: email.split('@')[0],
        nome: ADMIN_NOME.trim(),
        email,
        senhaHash: await bcrypt.hash(ADMIN_SENHA, 10),
        perfil: 'Administrador',
        ativo: true,
      })
    );
    console.log(`Cliente "${cliente.nome}" e administrador "${email}" criados.`);
  } finally {
    if (AppDataSource.isInitialized) await AppDataSource.destroy();
  }
}

main().catch((e) => {
  console.error('Erro no setup on-premise:', e);
  process.exit(1);
});
