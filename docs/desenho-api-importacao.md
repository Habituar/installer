# API de importação — desenho (Grupo C2, para aprovação; nada implementado)

**Hoje:** a aba "Via API REST" é fictícia — base `https://api.efinanceira.empresa.com.br/v1`, rotas
`/api/v1/eventos/opfin/lote` e `/api/v1/lotes/{id}/protocolo` que não existem. O que existe é
`POST /api/importacao/cadastro-endpoint` (só declarados, com o token de login da tela).

**Objetivo:** o sistema do cliente (core bancário) envia movimentações OpFin/PP e cadastros de declarados por HTTP,
com chave própria, passando pela **mesma** importação da tela (mesmas validações do CSV/.xlsx, CNPJ alfanumérico e
dígito verificador desde o início). A API **não** transmite nada à RFB: lotes continuam pela tela.

## 1. Autenticação — chave de API
- Formato: `efk_<prefixo 8>_<segredo 43>` (32 bytes aleatórios, base64url). Enviada em `Authorization: Bearer <chave>`.
- Mostrada **uma única vez** ao gerar (botão Copiar); o servidor guarda só **SHA-256 do segredo** (comparação em tempo
  constante) e o prefixo (para identificar na lista e na Auditoria).
- Tabela master `ChaveApi` (migrations PostgreSQL, SQL Server e Oracle): `id, clienteId, baseDadosId` (a chave vale
  para UMA base), `nome, prefixo, hashSegredo, escopos` (`importacao-movimentacoes`, `importacao-cadastros`),
  `criadoPor, criadoEm, ultimoUsoEm, ultimoUsoIp, revogadaPor, revogadaEm, expiraEm` (opcional).
- Escopo **só de importação**: a chave é aceita apenas em `/api/v1/importacao/*`; em qualquer outra rota, 401. O token
  de login não é aceito em `/api/v1`.
- Gerar/revogar/listar: novo recurso de permissão **"Chaves de API"** (ver, criar, excluir=revogar), padrão só
  Administrador; quem gera só dá escopos que ele mesmo tem (`importacao-*.executar`) — a mesma trava do B1.
  Revogada vale na hora (sem cache).

## 2. Rotas
| Método | Rota | Escopo |
|---|---|---|
| POST | `/api/v1/importacao/movimentacoes/opfin` | importacao-movimentacoes |
| POST | `/api/v1/importacao/movimentacoes/pp` | importacao-movimentacoes |
| POST | `/api/v1/importacao/declarados` | importacao-cadastros |
| GET | `/api/v1/importacao/{id}` | o da importação (resultado/andamento) |

## 3. Corpo (JSON, `Content-Type: application/json`, aceita `Content-Encoding: gzip`)
```json
{
  "idExterno": "core-20260308-001",
  "empresaCnpj": "12.ABC.345/01DE-35",
  "sistemaOrigem": "CORE01",
  "linhas": [
    { "numeroConta": "0001|013|12345678", "declaradoNI": "529.982.247-25", "tipoNI": "1",
      "nomeDeclarado": "FULANO DE TAL", "mesCaixa": "202603",
      "totalCreditos": 15400.00, "totalDebitos": 8200.00, "saldo": 7200.00 }
  ]
}
```
- `linhas`: **as colunas do modelo CSV** (mesmos nomes e regras); números com ponto decimal ou texto.
- `idExterno` obrigatório (idempotência, item 6); `sistemaOrigem` = código de Sistemas de Origem (obrigatório se o
  cliente exigir, como na tela).

## 4. Tamanho e processamento
- Máximo **10 MB** de corpo e **50.000 linhas** por chamada (`IMPORT_API_MAX_MB`, `IMPORT_API_MAX_LINHAS`); acima: 413
  com a orientação de dividir.
- Até **5.000 linhas**: síncrono (200 com o resultado). Acima: **202** + `Location: /api/v1/importacao/{id}` — consultar
  com GET (mesmo mecanismo de acompanhamento das importações da tela).
- Uma importação por vez por cliente (a vaga de hoje, corrigida no D2): ocupada → 409 + `Retry-After`.

## 5. Resposta
```json
{ "id": "imp_8f3c…", "idExterno": "core-20260308-001", "status": "concluido",
  "resumo": { "recebidas": 3, "importadas": 2, "atualizadas": 0, "comErro": 1, "retificacoes": 0 },
  "erros": [ { "linha": 3, "campo": "declaradoNI", "mensagem": "CNPJ inválido (dígito verificador incorreto): 12ABC34501DE36" } ],
  "avisos": [] }
```
- `linha` = posição em `linhas` (1 = primeira). Até 500 erros detalhados + total (como a tela).
- Códigos: 200 (inclusive com erros de linha — importação parcial, como CSV), 202, 400 (estrutura: JSON inválido,
  sem `linhas`, empresa de outro cliente — nada gravado), 401 (chave ausente/inválida/revogada/expirada),
  403 (escopo ou licença), 409 (vaga ocupada; `idExterno` repetido com outro conteúdo), 413, 429.

## 6. Idempotência / reenvio
- `ImportacaoLog` ganha `idExterno`, `hashConteudo` (SHA-256 do corpo normalizado) e `origem` (`api:<prefixo>`), com
  unicidade por cliente + rota + `idExterno` (migrations nos 3 bancos; no SQL Server, índice filtrado — o UNIQUE comum
  aceita um só NULL).
- Mesmo `idExterno` + mesmo conteúdo: devolve o resultado guardado, sem reprocessar (`Idempotent-Replay: true`).
  Mesmo `idExterno` + conteúdo diferente: 409 `IDEMPOTENCIA_CONFLITO`. Reenviar correção = novo `idExterno` (a
  importação já atualiza a mesma conta + mês, como no CSV).

## 7. Limite de requisições
- Por chave: **60 requisições/min** (`IMPORT_API_REQ_MIN`) — vale também no on-premise (hoje sem limite geral);
  excedeu: 429 + `Retry-After`. Mais a regra de uma importação por vez.

## 8. Auditoria e histórico
- Cada chamada: `importar_via_api`, recurso `importacao`, com chave (prefixo e nome), rota, `idExterno`, totais e IP.
- Gerar/revogar: `criar_chave_api` / `revogar_chave_api` (opção "Usuários e Acesso" do filtro).
- Histórico de importações mostra a origem "API (chave <nome>)". `ultimoUsoEm/Ip` atualizados a cada uso.
- Licença e limites (declarados, contas) iguais aos da tela.

## 9. Exemplo
```bash
curl -X POST "https://<servidor>:<porta>/api/v1/importacao/movimentacoes/opfin" \
  -H "Authorization: Bearer efk_ab12cd34_<segredo>" -H "Content-Type: application/json" \
  --data @movimentacoes.json
```

## 10. Aba "Via API REST" (dados reais)
- Busca `GET /api/importacao/api-info` (com o login da tela): rotas, limites, exemplo de corpo e resposta — a mesma
  fonte do servidor. Base = endereço pelo qual a tela está aberta (`window.location.origin`), então o curl exibido é
  copiável de verdade.
- Com permissão "Chaves de API": lista (nome, prefixo, escopos, criada por/em, último uso, situação) e botões Gerar
  (segredo mostrado uma vez) e Revogar (confirmação na página). Sem permissão: só a documentação.
- Saem a base fictícia e as rotas inexistentes. `/cadastro-endpoint` (login da tela) continua por compatibilidade.

## 11. Testes previstos
Chave: gerar (segredo uma vez, só hash gravado), revogar (401 na hora), escopo errado (403), rota fora de
`/api/v1/importacao` (401), expirada. Importação: mesma validação do CSV (CNPJ alfanumérico, DV, erros por linha),
idempotência (replay e conflito), 413, 429, 409 de vaga, 202 + GET. Integração em PostgreSQL e SQL Server.

## Decisões (aprovadas e implementadas no C2)

1. Limites: 10 MB, 50.000 linhas, síncrono até 5.000 linhas (acima: 202 + consulta), 60 req/min por chave — o limite vale só em `/api/v1/importacao/*`.
2. Uma chave por base de dados.
3. Validade opcional, com 12 meses sugeridos ao criar.
4. Gestão em Configurações → Chaves de API, com permissão própria (padrão: Administrador); a aba "Via API REST" mostra a documentação real e o atalho "Gerenciar chaves" para quem tem permissão.
5. IPs permitidos por chave (opcional): implementado (IPv4/IPv6 exatos e faixas IPv4 em CIDR).
6. Idempotência guardada na tabela `ImportacaoApi` (base do cliente) em vez de colunas novas no `ImportacaoLog`; recusa sem importação (ex.: 409 de vaga ocupada) não prende o `idExterno`.
