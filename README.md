# Instalador e-Financeira On-Premise (Windows Server)

Gera um único `efinanceira-onpremise-<versão>-setup.exe`. O cliente executa, responde poucas perguntas e o sistema fica rodando como serviço do Windows.

**Fluxo do cliente:** instala → informa banco, porta, CNPJ e o administrador → o instalador cria as tabelas, o cliente e o administrador → no primeiro login o sistema pede a **licença** (Configurações → Licença) → o administrador cola a chave gerada por você no painel master.

## O que o instalador coloca no servidor

- Node 22 embutido (`-NodeVersion` do `build.ps1`; o cliente não instala nada antes)
- Backend (`dist/`) e frontend buildado, servidos **na mesma porta** (padrão 3001)
- Serviço `efinanceira-api` (WinSW): inicia com o Windows e reinicia sozinho se cair
- Banco de dados do sistema, à escolha do cliente na instalação:
  - PostgreSQL 16 novo embutido (serviço `efinanceira-pg`, porta 5433, banco em UTF8), **ou**
  - PostgreSQL, **SQL Server** ou **Oracle** já existentes (o instalador só se conecta; não instala nada).
    O DBA precisa criar antes o banco (SQL Server: database vazio; Oracle: usuário/schema com service name) e um usuário
    com permissão para criar tabelas, índices e chaves. SQL Server: usuário `db_owner` do banco. Oracle: `CREATE SESSION`,
    `CREATE TABLE`, `CREATE SEQUENCE` e quota na tablespace; banco em AL32UTF8 (o sistema grava acentos).
    O Oracle usa o modo "thin" do driver: não precisa de Oracle Client, mas exige Oracle Database 12.1 ou mais novo.
- Segredos gerados na instalação (`JWT_SECRET`, `CONNECTION_CIPHER_KEY`, códigos de setup)

## Licença vinculada ao CNPJ

A licença é um token assinado com **chave privada (RS256)**. O painel master guarda a privada; a instalação valida com a chave **pública embutida no build** (`efinanceira-back\src\lib\chavePublicaLicenca.ts`), que não pode ser trocada pela tela nem pelo `backend.env`. A chave carrega o CNPJ do cliente e a instalação só a aceita se o CNPJ do Cliente cadastrado na instalação for o mesmo.
O formato antigo (HS256 com `LICENSE_SECRET`) **não é mais aceito**. Quem editasse o arquivo de ambiente conseguia emitir licenças.
**Trocar o par de chaves = novo build.** Copie o PEM de `license-public.pem` para `chavePublicaLicenca.ts`. O `build.ps1` confere os dois e se recusa a empacotar se forem diferentes.

## Preparação (uma vez)

1. **Copie os arquivos do backend** (pasta `backend-patch/`, ver abaixo) para o `efinanceira-back`, mantendo os caminhos, e faça deploy no master (Railway).
2. **Gere o par de chaves de licença:** `node installer\tools\gerar-chaves-licenca.mjs`. Ele cria `installer\license-public.pem` e uma pasta `chaves-licenca\` com a chave privada. **Guarde a privada com backup** e nunca a coloque no GitHub.
3. **No Railway (backend do master)** cadastre `LICENSE_PRIVATE_KEY_B64` e `LICENSE_PUBLIC_KEY_B64` (o script imprime os valores), mantendo o `LICENSE_SECRET` atual. Faça o deploy do backend com os arquivos novos. Sem isso o painel continua gerando licença no formato antigo e a instalação recusa.
4. **Frontend:** o build on-premise usa `VITE_MODO=onpremise` e `VITE_API_URL=/api`. Confira que o frontend lê esses nomes.

## Gerar o instalador

Requisitos: Windows x64, Node 22, [Inno Setup 6.3+](https://jrsoftware.org/isdl.php). Na pasta que contém `efinanceira-back`, `efinanceira-front` e `installer`:

```powershell
powershell -ExecutionPolicy Bypass -File installer\build.ps1 -Version 1.0.0
```

Resultado: `installer\output\efinanceira-onpremise-1.0.0-setup.exe`.

## Dependências externas (pasta `deps\`)

`deps\`, `stage\` e `output\` **não são versionados** (`.gitignore`). `stage\` é recriado do zero a cada build e `output\` recebe os instaladores gerados. Em `deps\` ficam três arquivos de terceiros; com internet, o `build.ps1` baixa cada um do endereço oficial quando falta (baixa para `<arquivo>.part` e só renomeia no fim, então um download interrompido não fica "em cache"):

| Arquivo em `deps\` | Origem (parâmetro do `build.ps1`) | Quando é usado |
|---|---|---|
| `node-v22.14.0-win-x64.zip` | `https://nodejs.org/dist/v22.14.0/node-v22.14.0-win-x64.zip` (`-NodeVersion`) | sempre (Node embutido) |
| `WinSW-x64.exe` | `https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe` (`-WinSWUrl`) | sempre (serviço do Windows) |
| `postgresql-installer.exe` | `https://get.enterprisedb.com/postgresql/postgresql-16.15-5-windows-x64.exe` (`-PgInstallerUrl`) | só no instalador **com** PostgreSQL (não com `-SemPostgres`) |

**SHA-256 conferido sempre:** o hash esperado de cada arquivo fica em `installer\deps.sha256` (versionado), com a versão e a origem. O `build.ps1` confere todo arquivo de `deps\`, baixado agora ou já presente. Se o hash não bate, ou o arquivo não tem linha em `deps.sha256`, o build para mostrando o arquivo, o hash esperado e o obtido; não apaga o arquivo nem baixa de novo (um download com hash errado fica como `<arquivo>.rejeitado`). Sem `-WinSWUrl`/`-PgInstallerUrl`, a origem é a registrada; outra origem só é aceita depois de registrar o hash dela. Trocar a versão de uma dependência = trocar a linha dela em `deps.sha256` (hash e origem) no mesmo commit. O WinSW não tem checksum oficial publicado: o hash registrado é o do arquivo já usado nos instaladores anteriores. Teste: `tools\testar-deps-sha256.ps1` (com `-Deps <pasta>`, confere também os arquivos de uma pasta `deps\`).

**Máquina de build sem internet:** baixe os arquivos acima em outra máquina, com **exatamente esses nomes**, e coloque-os em `installer\deps\` antes do build (o SHA-256 é conferido do mesmo jeito). Para só preparar ou conferir a pasta, sem exigir back/front/Inno Setup e sem gerar instalador:

```powershell
powershell -ExecutionPolicy Bypass -File installer\build.ps1 -SoDependencias              # os três
powershell -ExecutionPolicy Bypass -File installer\build.ps1 -SoDependencias -SemPostgres  # sem o PostgreSQL
```

Se faltar um arquivo e o download falhar, o build para com a mensagem "Não consegui obter <arquivo> de <endereço> (...) Baixe o arquivo em outra e coloque-o em ...\deps\<arquivo>".

## Entregar a um cliente

1. No painel master cadastre o cliente **com o CNPJ dele** e gere a licença tipo **on-premise**. A chave (`chave`) é o que você envia ao cliente.
2. O cliente instala, entra com o e-mail e a senha do administrador que ele mesmo definiu e cola a chave em Configurações → Licença.

## Atualização e desinstalação

| Situação | Comportamento |
|---|---|
| Atualização (rodar o novo setup por cima) | Pede a **confirmação do backup do banco** (obrigatória) e guarda a versão em uso em `previous\`. Depois para o serviço, troca os arquivos e reinicia. O backend aplica as migrations novas ao subir. `config\` e o banco são preservados. Se não conseguir guardar a versão anterior, cancela sem mexer em nada |
| Instalação anterior que não terminou | O instalador distingue **nova** (sem `config\backend.env`), **atualização** (`backend.env` e o marcador `config\instalacao.json`, gravado só no fim de uma execução bem-sucedida; nas instalações anteriores à 1.2.28, o serviço registrado) e **incompleta** (`backend.env` sem marcador e sem serviço). Na incompleta, reaproveita o banco e os segredos do `backend.env`, pede só instituição e administrador e conclui. Um `backend.env` existente nunca é recriado |
| Rollback (voltar para a versão anterior) | Menu Iniciar → *Voltar para a versão anterior (rollback)*, ou `scripts\rollback.ps1` como Administrador. Desfaz no banco só as migrations que a versão anterior não conhece, restaura `backend\`, `frontend\` e `scripts\` de `previous\`, sobe o serviço e confere o `/health`. A versão desfeita fica em `desfeita-<data>\`, e o log fica em `logs\rollback-*.log` |
| Administrador esqueceu a senha | Menu Iniciar → *Redefinir senha do administrador*, ou `scripts\redefinir-senha-admin.ps1` como Administrador. Lista os administradores, pede o login e a confirmação (SIM), gera uma senha temporária mostrada **só na tela** (nunca em log), obriga a troca no próximo login, desbloqueia/reativa o usuário, encerra as sessões dele e registra na Auditoria (`servidor:<usuário do Windows>`). Log sem a senha: `logs\redefinir-senha-admin.log`. Teste: `tools\testar-redefinir-senha-admin.ps1` (só em banco de teste) |
| Desinstalação | Remove o serviço e a regra de firewall. **Mantém** `config\`, `logs\`, `pgdata\` e `pgsql\` |

Pastas no cliente (`C:\Program Files\eFinanceira` por padrão):

- `config\backend.env`: variáveis e segredos, cifrados com DPAPI. **Faça backup:** perder a `ENCRYPTION_KEY` torna ilegível o certificado digital salvo, e perder o `JWT_SECRET` ou o `CONNECTION_CIPHER_KEY` torna ilegíveis as senhas das bases
- `previous\`: a versão anterior, guardada pela última atualização (para o rollback)
- `config\pg-admin.txt`: senha do superusuário do PostgreSQL embutido
- `config\rfb\`: certificados **públicos** da RFB para criptografia de lotes, um por ambiente
  (`cert-criptografia-producao.cer` e `cert-criptografia-producao-restrita.cer`). Vêm do pacote do backend
  (`src\recursos\rfb`, baixados de http://sped.rfb.gov.br/pasta/show/2064). Vencem uma vez por ano: o Administrador
  renova em Configurações > Certificados da RFB (ou trocando o arquivo da pasta), sem reinstalar; a tela avisa 30 dias
  antes. Uma atualização do instalador só troca o arquivo da pasta por um do pacote que vença **depois**.
  Teste da instalação desses arquivos: `tools\testar-certificados-rfb.ps1`.
- `logs\`: `install.log` e logs do serviço

## Checklist de release

Antes de entregar uma versão a qualquer cliente:

1. **CI verde no GitHub:** typecheck, testes e build nos três bancos (`.github/workflows/ci.yml` do backend). Não empacote a partir de commit com CI vermelho.
2. **Tudo commitado:** backend, frontend e `installer\`. O `build.ps1` marca o instalador como `-modificado` se o backend tiver alterações locais, e um instalador `-modificado` não vai para cliente.
3. **Versão nova:** `-Version` maior que a anterior. Ela aparece no `/health`, no pacote de diagnóstico e no nome do setup.
4. **Gerar:** `powershell -ExecutionPolicy Bypass -File installer\build.ps1 -Version X.Y.Z`. O script roda o typecheck e os testes do backend e o typecheck do front, e para na primeira falha. Não há opção para pular.
5. **Migrations só aditivas** (o teste `migracoesAditivas` barra o contrário): nada de apagar ou renomear tabela ou coluna no `up()`, e sempre com `down()`. É isso que permite o rollback sem restaurar backup.
6. **Teste de instalação limpa** numa VM: instalar, logar, colar a licença, conferir `http://localhost:<porta>/health` (`"status":"ok"`, versão certa).
7. **Teste de atualização** sobre a versão anterior, com dados: a página de backup aparece, `previous\` é criada, o `/health` mostra a versão nova e as telas principais abrem.
8. **Teste de rollback** na mesma VM: rodar o atalho de rollback, conferir no `/health` a versão anterior e os dados intactos. Depois reaplicar a atualização.
9. **Registrar a release:** tag `vX.Y.Z` nos repositórios (`git tag vX.Y.Z && git push --tags`), notas do que mudou e se há migration nova.
10. **Entregar:** o setup e as notas. Lembre o cliente de fazer o backup do banco antes de atualizar.

## Suporte remoto

- **Saúde:** `GET http://<servidor>:<porta>/health` (público, sem dados do cliente). Mostra banco, licença (prazo), certificado digital (prazo), RFB (disjuntor) e a versão instalada. Responde 503 se o banco estiver fora. Serve para monitoramento.
- **Pacote de diagnóstico:** em Configurações (Administrador), `GET /api/configuracoes/diagnostico`. Baixa um JSON com versão, ambiente, versão do banco, migrations aplicadas, saúde, configuração (só se cada variável está definida, nunca o valor de segredos) e as últimas linhas dos logs, com tokens e senhas mascarados. O cliente envia o arquivo ao suporte, sem precisar dar acesso à máquina.
- **Logs:** `logs\efinanceira-api.*.log` em JSON por linha (`ts`, `nivel`, `origem`, `msg`, `erro`), com rotação de 10 MB × 8. Requisições com erro 5xx ou acima de 5 s também entram no log.

## Pendências conhecidas

- **SQL Server e Oracle como banco do sistema: schema gerado a partir das entidades, mas ainda não testado contra servidores reais.** Teste os dois (instalação limpa + login) antes de vender. As migrations ficam em `src/migrations/mssql` e `src/migrations/oracle`; qualquer mudança futura de entidade precisa de migration nova para os três bancos.
- Backup agendado do banco, assinatura de código do `.exe` (sem ela o SmartScreen avisa) e o frontend ainda não revisado.
- Confira as versões dos downloads no `build.ps1` (Node, WinSW, PostgreSQL) antes de cada release.

## O que foi e o que não foi testado

- **Testado (Linux, PostgreSQL 16):** compilação do backend; migrations; criação do Cliente e do administrador (e repetição sem duplicar); backend servindo o frontend e a rota `/api/health`; login; licença de outro CNPJ recusada, licença adulterada recusada, licença do CNPJ certo aceita; validação RS256 só com a chave pública, ataque de troca de algoritmo e chave legada HS256.
- **Não testado (precisa de Windows):** `build.ps1`, o script do Inno Setup, `postinstall.ps1`, o serviço WinSW e o instalador silencioso do PostgreSQL. Teste numa VM antes de entregar a um cliente.
