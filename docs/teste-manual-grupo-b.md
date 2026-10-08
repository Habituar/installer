# Teste manual — Grupo B (permissões, Auditoria, senha, Excluir conta)

Base de **teste** (nunca a `efinanceira`), com uma empresa, um período aberto, uma movimentação já em lote e outra
pendente. Crie antes um usuário de cada perfil (senha nova na regra: 8+, maiúscula, número, especial — ex.:
`Teste@2026`). Perfil personalizado **Analista de Compliance**: marcar só *Visualizar* em Empresas, Períodos,
Declarados, Contas, Movimentações, Lotes e Auditoria (nada mais).

**403** = a tela mostra "sem permissão"/erro do servidor. Num item que o menu esconde, teste também a URL direta
(ex.: `/usuarios`): deve aparecer "Acesso negado".

## Administrador
- [ ] Menu: todos os itens (inclusive Usuários, Perfis, Auditoria, Configurações, Bases de Dados, Sistemas de Origem).
- [ ] Cria/edita/exclui em todas as telas; transmite lote; cria usuário Administrador.

## Operador
- [ ] Menu: Painel, Empresas, Períodos, Migração, Declarados, Contas, Movimentações, Lotes, Importação (as duas),
      Validação XML, Sistemas de Origem. **Sem** Usuários, Perfis, Auditoria, Configurações, Bases de Dados.
- [ ] Cria e edita contas, movimentações e lotes; envia lote; importa CSV/XML.
- [ ] Contas: **sem** botão Excluir; **com** Encerrar.
- [ ] Sistemas de Origem: só a lista, **sem** Novo/Editar/Excluir.
- [ ] URL `/configuracoes` e `/usuarios`: Acesso negado.

## Consulta
- [ ] Menu: Painel, Empresas, Períodos, Migração (só se tiver importação — não tem: some), Declarados, Contas,
      Movimentações, Lotes, Validação XML, Sistemas de Origem. **Sem** Importação.
- [ ] Nenhum botão de criar/editar/excluir/enviar; abre listas e detalhes.
- [ ] Movimentações → "Ver XML": funciona (só leitura).

## Analista de Compliance (personalizado)
- [ ] Menu: Painel, Empresas, Períodos, Declarados, Contas, Movimentações, Lotes, Auditoria. **Sem** Importação,
      Validação XML, Usuários, Perfis, Configurações, Sistemas de Origem.
- [ ] Vê tudo nessas telas, sem botões de ação; nenhum aviso "Não foi possível carregar…" ao trocar de tela.
- [ ] Auditoria abre (antes dava 403 para personalizado).
- [ ] Tire *Visualizar* de **Contas** no perfil, entre de novo: Contas some do menu, `/contas` dá Acesso negado e as
      demais telas continuam sem erro.
- [ ] No editor, marque *Criar* em Movimentações: aparece o aviso "Marcado também … Contas, Declarados, Períodos".
      Desmarque *Visualizar* de Contas: aviso "Desmarcado também … Movimentações – Criar".

## Casos de borda
- [ ] **Operador personalizado com "Usuários – criar"** (e Perfis – ver) tenta criar usuário **Administrador**:
      recusa "Só um Administrador cria ou promove um Administrador". Criar um **Operador** também recusa (ele daria
      permissões que o criador não tem); criar com um perfil igual ao dele passa.
- [ ] **Trocar senha** (Minha senha, primeiro acesso, Usuários → redefinir, Cadastro): `abcdefgh` recusa listando o
      que falta; `Teste@2026` aceita. A lista de regras marca ✓ conforme digita.
- [ ] **Auditoria → filtro Recurso**: cada opção traz registros do tipo (Movimentações traz OpFin e PP; Lotes,
      Períodos, Declarados, Contas, Usuários e Acesso, Sistemas de Origem, Bases de Dados). Antes só Importação e
      Configurações filtravam.
- [ ] **"Ver XML" de movimentação em lote**: baixa `evtMovOpFin_<id>_lote-LT-….xml` com o evento como foi no lote;
      o status da movimentação **não muda**.
- [ ] **"Ver XML" fora de lote**: baixa `…_previa.xml` e aparece o aviso "Prévia do XML gerada agora (não gravada…)";
      o status continua **Pendente**.
- [ ] **Excluir conta nova** (nunca usada): confirmação na página → excluída; aparece na Auditoria (Contas).
- [ ] **Excluir conta com movimentação / em lote / de recibo da migração**: "Conta com movimentações: use Encerrar"
      com o motivo; nada é apagado.
- [ ] **Perfil antigo** (salvo antes desta versão, com Movimentações – criar e sem Contas – ver): lança movimentação
      normalmente; ao abrir no editor, aviso "salvo antes das dependências… já em vigor".
