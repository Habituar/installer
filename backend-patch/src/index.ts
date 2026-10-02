import 'dotenv/config';
import 'reflect-metadata';
import express, { Request, Response } from 'express';
import cors from 'cors';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import path from 'path';

// Middlewares
import { authMiddleware } from './middlewares/auth.js';
import { clienteMiddleware } from './middlewares/cliente.js';
import { escopoMiddleware } from './middlewares/escopo.js';
import { checkModoLeitura } from './middlewares/modoLeitura.js';
import { superAuthMiddleware } from './middlewares/superAuth.js';
import { errorHandler } from './middlewares/errorHandler.js';
import AppDataSource from './lib/dataSource.js';
import { fecharTodasConexoes } from './lib/connectionManager.js';
import { fecharTodasConexoesBase } from './middlewares/database.js';
import { verificarLicencaAtiva, verificarLimiteEmpresa, verificarLimiteUsuario, verificarLimiteDeclarado, verificarLimiteConta } from './middlewares/verificarLicenca.js';
import { databaseMiddleware } from './middlewares/database.js';
import { adminPlanosRouter } from './routes/admin/planos.js';

// Rotas
import { authRouter } from './routes/auth.js';
import { empresasRouter } from './routes/empresas.js';
import { periodosRouter } from './routes/periodos.js';
import { declaradosRouter } from './routes/declarados.js';
import { contasRouter } from './routes/contas.js';
import { movimentacoesRouter } from './routes/movimentacoes.js';
import { lotesRouter } from './routes/lotes.js';
import { dashboardRouter } from './routes/dashboard.js';
import { usuariosRouter } from './routes/usuarios.js';
import { importacaoRouter } from './routes/importacao.js';
import { auditoriaRouter } from './routes/auditoria.js';
import { xmlRouter } from './routes/xml.js';
import { certificadoRouter } from './routes/certificado.js';
import { diretorRouter } from './routes/diretor.js';
import { adminTenantsRouter } from './routes/admin/tenants.js';
import { adminDashboardRouter } from './routes/admin/dashboard.js';
import { sistemasOrigemRouter } from './routes/sistemasOrigem.js';
import { perfisRouter } from './routes/perfis.js';
import { configuracoesRouter } from './routes/configuracoes.js';
import { conexoesRouter } from './routes/conexoes.js';
import { basesDadosRouter } from './routes/admin/basesDados.js';
import { basesDadosRouter2 } from './routes/bases-dados.js';

if (!process.env.LICENSE_SECRET && !process.env.LICENSE_PUBLIC_KEY_B64) {
  console.error('FATAL: defina LICENSE_PUBLIC_KEY_B64 (ou, no modelo legado, LICENSE_SECRET).');
  process.exit(1);
}

export const app = express();

const IS_ONPREMISE = process.env.DEPLOYMENT_TYPE === 'on-premise';

// Confiar no proxy do Railway/Render para express-rate-limit (on-premise: sem proxy na frente)
app.set('trust proxy', IS_ONPREMISE ? false : 1);
const PORT = Number(process.env.PORT) || 3000;
const IS_PROD = process.env.NODE_ENV === 'production';
const FRONTEND_URL = process.env.FRONTEND_URL;

// Aviso de segurança: códigos de setup ainda com o placeholder do .env.example
const PLACEHOLDER_CODE = 'TROQUE-POR-CODIGO-ALEATORIO-FORTE';
for (const nome of ['SUPER_ADMIN_MASTER_CODE', 'SETUP_ACTIVATION_CODE']) {
  if (process.env[nome] === PLACEHOLDER_CODE) {
    console.warn(`⚠️ AVISO DE SEGURANÇA: ${nome} está com o valor placeholder do .env.example. Defina um código aleatório forte.`);
  }
}

// 1. Helmet com headers de segurança
// On-premise roda em HTTP dentro da rede do cliente: CSP (upgrade-insecure-requests) e HSTS quebrariam o carregamento
app.use(IS_ONPREMISE ? helmet({ contentSecurityPolicy: false, hsts: false }) : helmet());

// 2. CORS: em produção apenas FRONTEND_URL/ADMIN_URL; localhost somente em desenvolvimento
const allowedOrigins = [
  ...(IS_PROD
    ? []
    : ['http://localhost:3000', 'http://127.0.0.1:3000', 'http://localhost:5173', 'http://localhost:3002']),
  ...(process.env.ADMIN_URL ? [process.env.ADMIN_URL] : []),
  ...(FRONTEND_URL ? [FRONTEND_URL] : []),
];

// On-premise: frontend e API na mesma origem, CORS não é necessário
if (!IS_ONPREMISE) app.use(
  cors({
    origin: (origin, callback) => {
      if (!origin) return callback(null, true);
      if (allowedOrigins.includes(origin)) {
        return callback(null, true);
      }
      return callback(new Error(`Origem não permitida pelo CORS: ${origin}`));
    },
    credentials: true,
    methods: ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization', 'X-Cliente-Id'],
  })
);

// 3. Body parser com limite de 1mb (upload de certificado usa multer, com limite próprio de 5mb)
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: true, limit: '1mb' }));

// 4. Rate Limiting
const generalLimiter = rateLimit({
  windowMs: 1 * 60 * 1000,
  max: 100,
  standardHeaders: true,
  legacyHeaders: false,
  message: {
    sucesso: false,
    mensagem: 'Limite de 100 requisições por minuto por IP excedido.',
    codigo: 'RATE_LIMIT_EXCEDIDO',
  },
});

const loginLimiter = rateLimit({
  windowMs: 1 * 60 * 1000,
  max: 5,
  skipSuccessfulRequests: true,
  standardHeaders: true,
  legacyHeaders: false,
  message: {
    sucesso: false,
    mensagem: 'Limite de 5 tentativas de login por minuto excedido.',
    codigo: 'LOGIN_RATE_LIMIT',
  },
});

// On-premise (rede local do cliente): sem limite geral de requisições
if (process.env.DEPLOYMENT_TYPE !== 'on-premise') {
  app.use('/api/', generalLimiter);
}
app.use('/api/auth/login', loginLimiter);
app.use('/api/super/login', loginLimiter);
app.use('/api/super/setup', loginLimiter);

// 4.1 On-premise: o backend também serve o frontend buildado (mesma porta).
// FRONTEND_DIR = pasta com o index.html gerado pelo "npm run build" do frontend (caminho absoluto).
// Vem ANTES da rota '/' abaixo para o index.html ter prioridade sobre o JSON de status.
const FRONTEND_DIR = process.env.FRONTEND_DIR;
if (FRONTEND_DIR) {
  app.use(express.static(FRONTEND_DIR));
}

// 5. Root & Health Check Endpoints
app.get('/', (req: Request, res: Response) => {
  res.json({
    servico: 'e-Financeira SaaS API - RFB v2.1.1',
    status: 'online',
    versao: '1.0.0',
    ambiente: process.env.NODE_ENV || 'development',
    endpoints: {
      health: '/health',
      documentacao: '/api/docs',
    },
  });
});

app.get('/health', (req: Request, res: Response) => {
  res.json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    version: '1.0.0',
    service: 'e-Financeira SaaS Backend (Railway Ready)',
  });
});

app.get('/api/health', (req: Request, res: Response) => {
  res.json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    version: '1.0.0',
  });
});

app.get('/api/docs', (req: Request, res: Response) => {
  res.json({
    titulo: 'e-Financeira SaaS API REST',
    versao: '1.0.0',
    leiauteRFB: 'Manual de Orientação do Leiaute da e-Financeira v2.1.1',
    modulos: {
      auth: [
        'POST /api/auth/login',
        'POST /api/auth/setup',
        'POST /api/auth/cadastro',
        'POST /api/auth/refresh',
        'GET /api/auth/me',
        'GET /api/auth/tenant-info',
      ],
      empresas: ['GET /api/empresas', 'GET /api/empresas/:id', 'POST /api/empresas', 'PUT /api/empresas/:id', 'DELETE /api/empresas/:id'],
      periodos: ['GET /api/periodos', 'GET /api/periodos/:id', 'POST /api/periodos', 'PUT /api/periodos/:id/abrir', 'PUT /api/periodos/:id/encerrar'],
      declarados: ['GET /api/declarados', 'GET /api/declarados/:id', 'POST /api/declarados', 'PUT /api/declarados/:id', 'DELETE /api/declarados/:id'],
      contas: ['GET /api/contas', 'GET /api/contas/:id', 'POST /api/contas', 'PUT /api/contas/:id', 'PUT /api/contas/:id/encerrar'],
      movimentacoes: [
        'GET /api/movimentacoes/opfin',
        'POST /api/movimentacoes/opfin',
        'POST /api/movimentacoes/opfin/:id/gerar-xml',
        'GET /api/movimentacoes/pp',
        'POST /api/movimentacoes/pp',
        'POST /api/movimentacoes/pp/:id/gerar-xml',
      ],
      lotes: ['GET /api/lotes', 'GET /api/lotes/:id', 'POST /api/lotes', 'PUT /api/lotes/:id/enviar', 'PUT /api/lotes/:id/consultar'],
      dashboard: ['GET /api/dashboard'],
      usuarios: [
        'GET /api/usuarios/me',
        'PUT /api/usuarios/minha-senha',
        'GET /api/usuarios',
        'POST /api/usuarios',
        'PUT /api/usuarios/:id',
        'PUT /api/usuarios/:id/desativar',
      ],
      importacao: ['POST /api/importacao/csv-opfin', 'POST /api/importacao/csv-pp', 'GET /api/importacao/modelo-opfin', 'GET /api/importacao/modelo-pp'],
      auditoria: ['GET /api/auditoria'],
      certificado: [
        'GET /api/certificado',
        'POST /api/certificado/upload',
        'POST /api/certificado/testar',
        'DELETE /api/certificado',
      ],
      xml: ['POST /api/xml/validar', 'GET /api/movimentacoes/opfin/:id/xml', 'GET /api/movimentacoes/pp/:id/xml', 'GET /api/lotes/:id/xml'],
      superAdmin: ['POST /api/super/login', 'POST /api/super/setup'],
      painelAdmin: [
        'GET /api/super/tenants',
        'GET /api/super/tenants/:id',
        'PUT /api/super/tenants/:id/ativar',
        'PUT /api/super/tenants/:id/suspender',
        'PUT /api/super/tenants/:id/cancelar',
        'PUT /api/super/tenants/:id/modo-leitura',
        'PUT /api/super/tenants/:id/plano',
        'PUT /api/super/tenants/:id/observacoes',
        'POST /api/super/tenants/:id/reset-senha-admin',
        'GET /api/super/dashboard',
      ],
    },
  });
});

// 6. Rotas da Aplicação
app.use('/api/auth', authRouter);
// Rotas de negócio: usam escopoMiddleware (isolamento pela BaseDados selecionada — ver
// src/middlewares/escopo.ts) + databaseMiddleware (conecta req.ds à BaseDados — ver
// src/middlewares/database.ts), em vez de clienteMiddleware (isolamento por clienteId do Usuario —
// ver src/middlewares/cliente.ts —, que continua valendo só para rotas de identidade/gestão:
// usuarios, perfis, conexoes).
app.use('/api/empresas', authMiddleware, escopoMiddleware, databaseMiddleware, verificarLicencaAtiva, verificarLimiteEmpresa, checkModoLeitura, empresasRouter);
app.use('/api/periodos', authMiddleware, escopoMiddleware, databaseMiddleware, verificarLicencaAtiva, checkModoLeitura, periodosRouter);
app.use('/api/declarados', authMiddleware, escopoMiddleware, databaseMiddleware, verificarLicencaAtiva, verificarLimiteDeclarado, checkModoLeitura, declaradosRouter);
app.use('/api/contas', authMiddleware, escopoMiddleware, databaseMiddleware, verificarLicencaAtiva, verificarLimiteConta, checkModoLeitura, contasRouter);
app.use('/api/movimentacoes', authMiddleware, escopoMiddleware, databaseMiddleware, verificarLicencaAtiva, checkModoLeitura, movimentacoesRouter);
app.use('/api/lotes', authMiddleware, escopoMiddleware, databaseMiddleware, verificarLicencaAtiva, checkModoLeitura, lotesRouter);
app.use('/api/dashboard', authMiddleware, escopoMiddleware, databaseMiddleware, verificarLicencaAtiva, dashboardRouter);
app.use('/api/usuarios', authMiddleware, clienteMiddleware, verificarLicencaAtiva, verificarLimiteUsuario, usuariosRouter); // identidade (Usuario é master) — continua por clienteId
app.use('/api/importacao', authMiddleware, escopoMiddleware, databaseMiddleware, checkModoLeitura, importacaoRouter);
app.use('/api/auditoria', authMiddleware, escopoMiddleware, databaseMiddleware, verificarLicencaAtiva, auditoriaRouter);
app.use('/api/xml', authMiddleware, escopoMiddleware, databaseMiddleware, verificarLicencaAtiva, checkModoLeitura, xmlRouter);
app.use('/api/certificado', authMiddleware, escopoMiddleware, databaseMiddleware, verificarLicencaAtiva, certificadoRouter);
app.use('/api/sistemas-origem', authMiddleware, escopoMiddleware, databaseMiddleware, verificarLicencaAtiva, sistemasOrigemRouter);
app.use('/api/perfis', authMiddleware, clienteMiddleware, verificarLicencaAtiva, perfisRouter); // identidade (PerfilCustom é master) — continua por clienteId
app.use('/api/configuracoes', authMiddleware, configuracoesRouter); // sem escopoMiddleware/databaseMiddleware aqui: PUT /licenca precisa funcionar mesmo sem BaseDados selecionada (recuperar de licença vencida); GET /uso-atual aplica os dois só nela mesma, dentro do router
app.use('/api/conexoes', authMiddleware, clienteMiddleware, conexoesRouter); // legado SaaS (ConexaoCliente/BYODB) — não usado no fluxo BaseDados; mantido por clienteId, sem alteração
// Instalação on-premise: lista de BaseDados cadastradas para a tela de seleção pós-login — qualquer usuário autenticado
app.use('/api/bases-dados', authMiddleware, basesDadosRouter2);

// 6.1 Painel Administrativo — SuperAdmin foi eliminado: o perfil de acesso total agora é 'Diretor'
// (Usuario fixo, sem clienteId) — superAuthMiddleware (alias de diretorMiddleware, ver
// middlewares/superAuth.ts) só checa req.userPerfil, já populado por authMiddleware — por isso vem
// SEMPRE depois dele agora.
// ATENÇÃO: diretorRouter contém /login e /setup (sem auth) + /usuarios (com auth via middleware interno)
// As rotas mais específicas (/tenants, /dashboard) devem vir ANTES do router genérico
app.use('/api/super/tenants', authMiddleware, superAuthMiddleware, adminTenantsRouter);
app.use('/api/super/dashboard', authMiddleware, superAuthMiddleware, adminDashboardRouter);
app.use('/api/super/planos', authMiddleware, superAuthMiddleware, adminPlanosRouter);
// CRUD + teste de conexão das BaseDados on-premise. GET é livre para qualquer autenticado;
// POST/PUT/DELETE exigem a permissão granular 'gerenciarBases' (checkPermissao, ver
// middlewares/permissao.ts) dentro do próprio router — Diretor e Administrador sempre passam,
// demais perfis dependem de PerfilCustom.permissoes.gerenciarBases. O escopo (todas as bases para
// Diretor, só a própria para os demais) é aplicado dentro de cada handler, não aqui.
app.use('/api/admin/bases-dados', authMiddleware, basesDadosRouter);
app.use('/api/super', diretorRouter); // /login e /setup são públicos; /usuarios agora protegido internamente

// 6.2 On-premise: qualquer rota que não seja da API cai no index.html (React Router)
if (FRONTEND_DIR) {
  app.get(/^\/(?!api\/|health).*/, (_req: Request, res: Response) => {
    res.sendFile(path.join(FRONTEND_DIR, 'index.html'));
  });
}

// 7. Error Handler
app.use(errorHandler);

// O DataSource (TypeORM) precisa estar conectado antes de o Express aceitar requisições
let server: ReturnType<typeof app.listen> | undefined;

AppDataSource.initialize()
  .then(async () => {
    console.log(`🗄️  Banco de dados conectado (${AppDataSource.options.type})`);
    // Aplica as migrations pendentes no startup (equivalente ao antigo "prisma migrate deploy").
    // Desative com DB_RUN_MIGRATIONS=false se preferir rodar "npm run migration:run" no pipeline de deploy.
    if (process.env.DB_RUN_MIGRATIONS !== 'false') {
      const aplicadas = await AppDataSource.runMigrations();
      if (aplicadas.length > 0) console.log(`🧱 Migrations aplicadas: ${aplicadas.map((m) => m.name).join(', ')}`);
    }
    server = app.listen(PORT, '0.0.0.0', () => {
      console.log(`🚀 [e-Financeira Backend] Servidor rodando na porta ${PORT}`);
      console.log(`📋 Health check: http://0.0.0.0:${PORT}/health`);
      console.log(`📚 Documentação: http://0.0.0.0:${PORT}/api/docs`);
    });
  })
  .catch((err) => {
    console.error('FATAL: não foi possível conectar ao banco de dados:', err);
    process.exit(1);
  });

// Graceful Shutdown
const shutdown = (signal: string) => {
  console.log(`\n🛑 Sinal ${signal} recebido. Encerrando servidor graciosamente...`);
  const encerrar = async () => {
    await fecharTodasConexoes();
    await fecharTodasConexoesBase();
    if (AppDataSource.isInitialized) await AppDataSource.destroy().catch(() => {});
    console.log('✅ Servidor finalizado com sucesso.');
    process.exit(0);
  };
  if (server) server.close(() => void encerrar());
  else void encerrar();
  setTimeout(() => {
    console.error('⚠️ Timeout de encerramento.');
    process.exit(1);
  }, 10000);
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

export default app;
