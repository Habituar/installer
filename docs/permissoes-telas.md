# Permissões e dependências entre telas (Grupo B1)

Fonte única: `efinanceira-back/src/middlewares/permissoes.ts` — catálogo de recursos e ações, perfis padrão,
dependências entre telas e a regra efetiva (`permissaoEfetiva`). Dela saem:

- a checagem das rotas da API (`checkPermissao` / `checkPermissaoAlguma`);
- a matriz de permissões do usuário, devolvida no login e em `GET /api/auth/me` — o front usa **só** ela para o menu
  e para as telas (`front/src/utils/calcularPermissao.ts`);
- o catálogo do editor de perfis (`GET /api/perfis/catalogo`).

Que permissão abre cada tela — uma tabela para o menu e para a rota: `front/src/utils/acessoTelas.ts`.

## Perfis padrão

Diretor e Administrador: tudo (um perfil personalizado residual não rebaixa o Administrador).

| Recurso | Operador | Consulta |
|---|---|---|
| Empresas, Períodos, Declarados, Contas, Movimentações | ver, criar, editar | ver |
| Lotes | ver, criar, enviar | ver |
| Importação: Movimentações / Cadastros | ver, executar | — |
| Validação XML | ver, executar | ver |
| Sistemas de Origem | ver | ver |
| Usuários, Perfis, Configurações, Auditoria, Bases de Dados | — | — |

## Telas: o que abre e o que cada uma lê da API

| Tela | Abre com | Lê da API (além do próprio recurso) |
|---|---|---|
| Painel | qualquer usuário | `GET /dashboard` (contagens), certificado (aviso de vencimento) |
| Seletor de empresa (topo, todas as telas) | — | `GET /empresas`: liberado para quem lê **qualquer** módulo do e-Financeira |
| Empresas | Empresas – ver | — |
| Períodos | Períodos – ver | `GET /empresas/:id` e responsáveis (Empresas **ou** Períodos – ver), certificado |
| Migração | Períodos – ver **ou** Importação: Movimentações – ver | recibos do sistema anterior: Importação: Movimentações – ver (a seção some sem ela) |
| Declarados | Declarados – ver | — |
| Contas | Contas – ver | lista de declarados (para escolher o titular) |
| Movimentações | Movimentações – ver | contas, declarados e períodos (para lançar); lotes (abrir o lote do evento original — o botão fica inativo sem Lotes – ver) |
| Lotes | Lotes – ver | movimentações e períodos (só no "Novo Lote") |
| Importação: Movimentações | Importação: Movimentações – ver | períodos; sistemas de origem ativos |
| Importação: Cadastros | Importação: Cadastros – ver | sistemas de origem ativos |
| Validação XML | Validação XML – ver | — |
| Sistemas de Origem | Sistemas de Origem – ver | — (botões por ação: criar/editar/excluir) |
| Usuários | Usuários – ver | perfis personalizados (para atribuir) |
| Perfis de Acesso | Perfis – ver | catálogo de permissões |
| Configurações | Configurações – ver | — |
| Auditoria | Auditoria – ver | — |
| Bases de Dados | Bases de Dados – ver | — |

Listas de apoio carregadas por todas as telas (`App.tsx`): só as que o perfil pode ver; as outras ficam vazias, sem
mensagem de erro. Status de transmissão (faixa do topo): só com Lotes – ver.

## Dependências (o editor marca; o servidor completa ao salvar)

Toda ação também exige ver o próprio recurso.

| Ação | Exige ver |
|---|---|
| Contas – criar / editar | Declarados |
| Movimentações – criar / editar | Contas, Declarados, Períodos |
| Lotes – criar | Movimentações, Períodos |
| Importação: Movimentações – executar | Períodos |
| Usuários – criar / editar | Perfis |

Desmarcar "ver" de um recurso no editor desmarca também as ações de outras telas que dependem dele.

## Usuários e Perfis — trava contra escalada

- Só um Administrador (perfil Administrador, Diretor ou personalizado com acesso total) cria, promove, altera ou
  desativa um Administrador, e cria/altera/exclui um perfil com acesso total.
- Quem não é Administrador só concede (a um usuário ou num perfil) permissões que ele mesmo tem.

## Rotas de leitura que continuam livres para quem está logado

`GET /dashboard` (contagens), `GET /importacao/status-atual` (faixa de importação do próprio cliente),
`GET /usuarios/me`, `GET /auth/me`.
