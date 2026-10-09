# Pendências para o 1.2.28

Ficaram de fora do hotfix 1.2.27 (correção do PostgreSQL, inicialização robusta do serviço, erro real na falha do
instalador e `index.html` sem cache). Nada abaixo está implementado. Linhas citadas: back `main` `f9809e7`, front
`main` `b68a895`, installer `main` `bb7e9ce`.

## 1. Detecção de banco existente antes de pedir o administrador

**O quê:** depois do "Testar conexão", o instalador detecta o que há no banco e, se já houver o e-Financeira
configurado, pula as páginas de instituição e administrador e mostra na tela: instituição (CNPJ), administradores
(login/e-mail) e "nenhum usuário será criado". Banco com tabelas de outro sistema pede confirmação; mais de um cliente
ou versão de banco mais nova que o instalador bloqueia. O setup deixa de ser silencioso: código de saída próprio
para "já configurado", mostrado pelo instalador.

**Motivo:** instalando sobre um banco com dados, o instalador pediu os dados do administrador e os descartou sem
avisar — `onpremise-setup.ts` encerra com "Instalação já configurada: nenhum dado criado." quando já existe `Cliente`.
PostgreSQL e Oracle não têm driver no Windows: a detecção precisa de um script empacotado (Node + drivers) rodado da
pasta temporária.

## 2. Estado de instalação incompleta

**O quê:** o `postinstall.ps1` grava `config\instalacao.json` (versão e data) só no fim de uma instalação
bem-sucedida. O instalador passa a distinguir **nova** (sem `backend.env`), **atualização** (marcador presente; em
instalação antiga sem marcador, serviço `efinanceira-api` registrado) e **incompleta** (`backend.env` sem marcador e
sem serviço). Incompleta: reaproveita o banco do `backend.env`, pede só instituição e administrador e conclui.
Instalação nova que falha deixa o serviço instalado e parado (inicialização manual); atualização que falha oferece o
rollback (`rollback.ps1`, pasta `previous\`).

**Motivo:** o `backend.env` é gravado antes da criação das tabelas; depois de uma falha, a nova execução vira
"atualização" (`IsUpgrade` = `backend.env` existe) e nunca cria o administrador — foi o que aconteceu na máquina do
teste do 1.2.26 (recuperação manual descrita na conversa do hotfix).

## 3. Script local de reset de senha do administrador

**O quê:** script no back (ex.: `scripts/redefinirSenhaAdmin`) e atalho no menu Iniciar "Redefinir senha do
administrador", que exige administrador do Windows (como o atalho de rollback). Gera senha temporária, força a troca
no próximo login, desbloqueia o usuário e registra na auditoria (`LogAuditoria`).

**Motivo:** no on-premise não há rota nem script para o caso "o único administrador esqueceu a senha". Hoje só um
Administrador troca a senha de outro (`PUT /api/usuarios/:id`) e o Diretor redefine a do administrador de um cliente
(`POST /api/super/tenants/:id/reset-senha-admin`), recurso do SaaS.

## 4. Login do instalador

**O quê:** aceitar qualquer caixa (normalizar para minúsculas antes de validar, como o setup já faz) e e-mail: com
`@`, se igual ao e-mail informado (ou com e-mail vazio), o login vira a parte antes do `@` e o instalador avisa que dá
para entrar com o e-mail ou com o login; diferente do e-mail, recusa explicando. A mensagem de erro diz o caractere e
a posição (ex.: `O caractere "@" (posição 14) não é permitido no login`). No back, a busca por login passa a ignorar
caixa nos 3 bancos (`LOWER(login) = LOWER(:x)`), com checagem prévia de logins que só diferem na caixa.

**Motivo:** o instalador recusou `wesdras.alves@zapsistemas.com.br` com uma regra (`efinanceira.iss`, `LoginValido`)
mais estrita que a tela de login, que aceita e-mail (com `@` busca pelo e-mail, `authService.ts:82-85`). A busca por
login é exata: ignora caixa no SQL Server (collation) e não no PostgreSQL/Oracle.

## 5. Textos de "Esqueceu a senha?" e do aviso de perda de acesso no on-premise

**O quê:** com `isOnPremise`, trocar o texto por: "Peça a um administrador do e-Financeira da sua instituição para
redefinir sua senha (Configurações → Usuários). Se você é o único administrador, o responsável pelo servidor pode
redefini-la pelo atalho 'Redefinir senha do administrador' no menu Iniciar do servidor." (depende do item 3).

**Motivo:** a tela do on-premise manda procurar `suporte@efinanceira.com.br`, contato do SaaS, e não diz o
procedimento real de redefinição.

## 6. `SUPORTE_CONTATO` do on-premise

**O quê:** chave `SUPORTE_CONTATO=chamados.cfi@zapsistemas.com.br` em `config\global-defaults.env` (vai para o
`backend.env` como os demais valores globais), exposta ao front e exibida **só quando `isOnPremise`** nos 4 pontos que
hoje mostram o e-mail do SaaS:
- `src/pages/Login.tsx:259` (aviso de perda de acesso)
- `src/pages/Login.tsx:323` (rodapé "Suporte:")
- `src/components/layout/Layout.tsx:224` (faixa "LICENÇA SUSPENSA")
- `src/pages/ContaCancelada.tsx:38`

**Motivo:** o contato não pode ficar fixo no código (troca exigiria novo build do front) e o do SaaS não serve ao
cliente on-premise. Sem a chave definida, o on-premise não mostra contato.

## 7. Deadlock na limpeza dos testes de integração em paralelo

**O quê:** colocar a limpeza (`after` → `limpar()`) dos testes de `tests/integracao/` dentro do `comRetryDeadlock`
(`lib/deadlock.ts`, já existente); depois disso, voltar a rodar a integração em paralelo.

**Motivo:** com os arquivos rodando em paralelo no mesmo banco de teste (`efinanceira_migracao_teste`), o `DELETE` da
limpeza de "migração — trava de contas omitidas" foi escolhido como vítima de deadlock (todos os testes do arquivo
passaram; falhou o hook). Em série (`--test-concurrency=1`) não ocorre — é como a integração está sendo rodada.

## 8. Oracle: `typeorm_migrations` sem aspas — sem teste em Oracle real

**O quê:** rodar em Oracle real o rollback (`scripts/reverterParaVersao.ts`) e o pacote de diagnóstico
(`services/diagnostico.ts`), que agora usam `lib/migracoesAplicadas.ts` (identificadores citados pelo driver), e a
integração (`tests/integracao/*.test.ts` com `CRS_TESTE_ORA_*`).

**Motivo:** no Oracle o TypeORM cria `"typeorm_migrations"` citada em minúsculas; o SQL antigo, sem aspas, procuraria
`TYPEORM_MIGRATIONS` (ORA-00942). A correção (back `afb1afb`) foi conferida só como texto gerado pelo driver Oracle e
executada no PostgreSQL e no SQL Server — não havia Oracle disponível.

## 9. PostgreSQL embutido

Trocar o 16.4-1 (08/2024) pela correção mais nova da série 16 publicada pela EnterpriseDB (há até a 16.12-1; `-PgInstallerUrl` no `build.ps1`), testando instalação nova e atualização.

**Feito no build (1.2.28):** o padrão passou a ser o 16.15-5, registrado em `deps.sha256` com o SHA-256 conferido com o publicado pela EnterpriseDB. O `build.ps1` confere o SHA-256 do PostgreSQL, do Node e do WinSW sempre, inclusive do arquivo já presente em `deps\` (antes reaproveitava pelo nome e só conferia o Node, e só ao baixar); teste em `tools\testar-deps-sha256.ps1`. **Falta:** testar instalação nova e atualização com o 16.15-5.

## 10. Certificados de criptografia da RFB

Renovar certificados de criptografia RFB: Produção vence em 25/11/2026, Produção Restrita em 23/12/2026; baixar os novos em http://sped.rfb.gov.br/pasta/show/2064 e distribuir.

Como distribuir sem reinstalar: Configurações → Certificados da RFB → Atualizar (por ambiente), ou trocar o arquivo em `config\rfb\` (`cert-criptografia-producao.cer` / `cert-criptografia-producao-restrita.cer`). O pacote seguinte deve trazê-los em `efinanceira-back/src/recursos/rfb/` (o `build.ps1` falha com certificado vencido e avisa a 30 dias). O "Testar Conectividade" mostra se a chave do servidor confere com o certificado em uso.

**Verificado em 09/10/2026 (1.2.28): ainda não há certificados novos.** A página do SPED (pasta 2064) publica só os
mesmos do pacote — Produção "Certificado efinanceira (Ambiente de Produção)_2025", validade até 25/11/2026, thumbprint
`33ff3179bda29a7e25daa52631defc19d1105b2d`; Produção Restrita, validade 23/12/2025 a 23/12/2026, thumbprint
`cc242988a739caa7757b29e2a900ae35519cdb39` — iguais aos de `efinanceira-back/src/recursos/rfb/`. Nada foi trocado na
1.2.28. **Continua pendente:** conferir a página de novo antes de 25/11/2026 (o build avisa a 30 dias, a partir de
26/10/2026) e, quando publicarem, distribuir pela tela de Configurações e trocar os arquivos do pacote.

## 11. Limpeza de dados de teste com CNPJ alfanumérico

Confirmar na próxima versão do Manual do Desenvolvedor (hoje v2.7, seção 8) se o endpoint `limpezaDadosTesteProducaoRestrita` aceita CNPJ alfanumérico: o texto atual diz "somente números e sem formatação", anterior ao aviso da RFB de 29/04/2026 sobre o CNPJ alfanumérico (os XSDs v1_5_0 já aceitam `[0-9A-Z]{14}`). O sistema envia o CNPJ como está (maiúsculas e dígitos, sem pontuação); se a RFB devolver HTTP 400 para CNPJ com letras, a tela mostra a observação (`notaLimpezaCnpjAlfanumerico` em `routes/configuracoes.ts`). Se o manual novo pedir outra forma, ajustar `RfbService.limparDadosTesteProducaoRestrita`.

## 12. 409 "importação em andamento" intermitente (achado no D2 — CORRIGIDO no back)

**Causa (bug real, não isolamento de teste):** na importação síncrona a rota respondia ao cliente e só depois, no `finally` de `comArquivoTemporario` (`routes/importacao.ts`), esperava apagar o arquivo temporário para então liberar a vaga do cliente (`finalizarJob`). Quem manda a importação seguinte assim que recebe a resposta (o teste do gerador, um script, a API de importação) caía nessa janela e levava 409 sem haver importação nenhuma. Com a máquina folgada a janela é de milissegundos (12 rodadas seguidas do `geradorDadosTeste.mssql.test.ts` passaram); sob carga (suíte inteira) apareceu 1 vez. Não há trava presa entre processos: a vaga é em memória, por processo.

**Correção:** a vaga é liberada antes de apagar o temporário (síncrona e assíncrona). Teste: `tests/importacaoVagaTenant.test.ts` atrasa a exclusão do temporário em 300 ms — sem a correção a 2ª importação leva 409; com ela, não — e confere que duas importações realmente simultâneas do mesmo cliente continuam com 409.

## 13. Integração em PostgreSQL: `npm run test:integracao:pg`

Roda `tests/integracao/*.test.ts` com `DB_TYPE=postgres` (o tipo das colunas de texto sai de `DB_TYPE` ao carregar; com o `DB_TYPE=mssql` do `.env` o PostgreSQL não monta as tabelas). Conexão por `PG_TESTE_HOST/PORT/DB/USER/PASSWORD` (banco com "teste" no nome) e `JWT_SECRET`; `CRS_TESTE_XML` com o caminho do `teste1mb.xml`. Ver o README do back, seção Testes. Observação: rodando de um worktree, o caminho padrão do `teste1mb.xml` não existe e o teste do CRS sai como skip — informe `CRS_TESTE_XML`.

## 14. Sobras dos grupos A, D, D2, B e C (seção 9 do levantamento do manual)

- **XML de PP na Importação — correção completa na 1.2.29:** na 1.2.28 a tela recusa `.xml` na opção Previdência Privada ("Para Previdência Privada, use CSV ou Excel (.xlsx)"), porque converteria os evtMovPP pelo leiaute de OpFin e o servidor recusaria todas as linhas (levantamento, item 2). Na 1.2.29: o servidor ler o evtMovPP (planos, aportes, resgates, portabilidade), como já lê o evtMovOpFin em `cadastro-xml`, e a tela voltar a aceitar o XML de PP.
- **Configurações → Banco de Dados (banco dedicado):** confirmar se tem efeito no on-premise; se não, tirar da tela (item 6).
- **Certificado digital:** conferir o CNPJ do certificado com o da empresa declarante antes de transmitir (item 12; cadeia ICP-Brasil e vencimento já conferidos no Grupo A).
- **Pacote de diagnóstico:** botão na tela (hoje só `GET /api/configuracoes/diagnostico`) (item 14).
- **Para o manual, a documentar ou verificar:** backup e restauração (com o DPAPI do `config\`), requisitos mínimos, procedimento de reinício do serviço, situação "Fechado" do período, "Lembrar-me" e "Esqueceu a senha?" no login, reimportação com `forcar=true`, vírgula decimal no CSV de OpFin, textos oficiais dos códigos MS e o e-mail de suporte (itens 15–17 e 19–25; ver também os itens 3, 5 e 6 desta lista).
- **Migração:** premissas P1, P2 e P5–P12 sem prova na RFB (item 19).

## 15. API de importação (Grupo C2) — limites conhecidos

- Limites: 60 requisições/min por chave (pelo prefixo) e, para chave inválida, 20 tentativas/min por IP (acima: 429; `IMPORT_API_FALHAS_IP_MIN`). A chave é conferida antes: chave válida nunca é barrada pelo limite por IP. Os contadores ficam em memória (zeram ao reiniciar o serviço).
- Tabelas `ChaveApi` (master) e `ImportacaoApi` (base): migrations testadas em PostgreSQL e SQL Server; Oracle sem teste real (item 8).
- No histórico de importações e na Auditoria, o "usuário" das chamadas pela API é `chave:<prefixo>` (a tela não traduz para o nome da chave).
