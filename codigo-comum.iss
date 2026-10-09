{ Codigo Pascal compartilhado pelo efinanceira.iss e pelos testes do instalador, incluido DENTRO de [Code].
  Cuidados: comentario so em sintaxe Pascal (nunca ";") e nenhuma linha comecando com o caractere de diretiva do
  pre-processador. Sem acentos nas mensagens, como no restante do instalador. }

{ O Pascal Script do Inno so tem LoadStringFromFile para AnsiString (bytes crus, sem codepage) —
  nao existe overload para String (Unicode) que decodifique UTF-8 sozinho, e um cast direto
  String(AnsiStr) reinterpreta cada byte pela codepage ANSI da maquina, dando o mojibake classico
  ("ção" grava 2 bytes em UTF-8 — 0xC3 0xA7 — que viram "Ã§" se lidos um a um como CP1252). Por
  isso decodificamos o UTF-8 na mao aqui: o PowerShell grava o arquivo com Out-File -Encoding utf8
  (UTF-8 com BOM), pulamos o BOM e convertemos byte a byte pra Unicode. }
function Utf8Decode(const S: AnsiString): String;
var
  I, Len, Inicio: Integer;
  B1, B2, B3, B4: Byte;
  Code: LongInt;
begin
  Result := '';
  Len := Length(S);
  Inicio := 1;
  if (Len >= 3) and (Ord(S[1]) = $EF) and (Ord(S[2]) = $BB) and (Ord(S[3]) = $BF) then
    Inicio := 4;   { pula o BOM UTF-8 }
  I := Inicio;
  while I <= Len do
  begin
    B1 := Ord(S[I]);
    if B1 < $80 then                        { ASCII puro: 1 byte }
    begin
      Result := Result + Chr(B1);
      Inc(I);
    end
    else if (B1 and $E0) = $C0 then         { 110xxxxx 10xxxxxx: 2 bytes }
    begin
      if I + 1 <= Len then
      begin
        B2 := Ord(S[I + 1]);
        Result := Result + Chr(((B1 and $1F) shl 6) or (B2 and $3F));
      end;
      I := I + 2;
    end
    else if (B1 and $F0) = $E0 then         { 1110xxxx 10xxxxxx 10xxxxxx: 3 bytes (a maioria dos acentos) }
    begin
      if I + 2 <= Len then
      begin
        B2 := Ord(S[I + 1]);
        B3 := Ord(S[I + 2]);
        Result := Result + Chr(((B1 and $0F) shl 12) or ((B2 and $3F) shl 6) or (B3 and $3F));
      end;
      I := I + 3;
    end
    else if (B1 and $F8) = $F0 then         { 11110xxx ...: 4 bytes -> par substituto UTF-16 }
    begin
      if I + 3 <= Len then
      begin
        B2 := Ord(S[I + 1]);
        B3 := Ord(S[I + 2]);
        B4 := Ord(S[I + 3]);
        Code := ((B1 and $07) shl 18) or ((B2 and $3F) shl 12) or ((B3 and $3F) shl 6) or (B4 and $3F);
        Code := Code - $10000;
        Result := Result + Chr($D800 + (Code shr 10)) + Chr($DC00 + (Code and $3FF));
      end;
      I := I + 4;
    end
    else
      Inc(I);   { byte invalido/continuacao solta: ignora }
  end;
end;

{ Resumo do erro gravado pelo postinstall.ps1 em logs\install-erro.txt (linha util do erro + "Etapa: ..."), UTF-8
  com BOM. Vazio se o arquivo nao existir (falha antes de o postinstall gravar, ou postinstall antigo). }
function LerResumoErroInstalacao(const Arquivo: String): String;
var
  Bruto: AnsiString;
begin
  Result := '';
  if FileExists(Arquivo) and LoadStringFromFile(Arquivo, Bruto) then
    Result := Trim(Utf8Decode(Bruto));
end;

{ Estado da pasta de instalacao (item 2 das pendencias 1.2.28). O config\instalacao.json (marcador) so e gravado
  pelo postinstall.ps1 no FIM de uma instalacao ou atualizacao bem-sucedida.
  - NOVA:        sem config\backend.env.
  - ATUALIZACAO: backend.env e marcador; ou, em instalacao anterior a 1.2.28 (sem marcador), o servico registrado.
  - INCOMPLETA:  backend.env sem marcador e sem servico - uma instalacao nova que falhou no meio. Reaproveita o
                 backend.env (banco e segredos) e so pede instituicao e administrador.
  So o estado NOVA grava um backend.env novo (segredos e ENCRYPTION_KEY novos), e ele so existe SEM backend.env:
  errar entre ATUALIZACAO e INCOMPLETA nunca recria o backend.env. A mesma regra esta em Get-ModoInstalacao
  (scripts\postinstall.ps1), que confere o modo que o instalador mandou. }
const
  INSTALACAO_NOVA = 0;
  INSTALACAO_ATUALIZACAO = 1;
  INSTALACAO_INCOMPLETA = 2;

function ClassificarInstalacao(TemBackendEnv, TemMarcador, TemServico: Boolean): Integer;
begin
  if not TemBackendEnv then
    Result := INSTALACAO_NOVA
  else if TemMarcador or TemServico then
    Result := INSTALACAO_ATUALIZACAO
  else
    Result := INSTALACAO_INCOMPLETA;
end;

{ Mostrada ao chegar na pagina da instituicao, numa instalacao incompleta }
function MensagemInstalacaoIncompleta(const Pasta: String): String;
begin
  Result := 'Foi encontrada uma instalacao anterior que nao terminou nesta pasta (' + Pasta + '): a configuracao ' +
    '(config\backend.env) existe, mas a instalacao nao foi concluida e o servico do e-Financeira nao esta registrado.' + #13#10#13#10 +
    'O banco de dados e a porta configurados nela serao reaproveitados. Informe a instituicao e o ' +
    'administrador para concluir a instalacao.';
end;

{ Nome do modo no install-params.json (o postinstall.ps1 confere com a mesma regra) }
function NomeModoInstalacao(Estado: Integer): String;
begin
  case Estado of
    INSTALACAO_ATUALIZACAO: Result := 'atualizacao';
    INSTALACAO_INCOMPLETA: Result := 'incompleta';
  else
    Result := 'nova';
  end;
end;

{ Aviso de "banco ja configurado" gravado pelo setup (onpremise-setup.ts) em logs\install-aviso.txt, UTF-8 com BOM:
  o banco ja tinha uma instalacao do e-Financeira e o administrador informado NAO foi criado. Vazio = sem aviso. }
function LerAvisoInstalacao(const Arquivo: String): String;
begin
  Result := LerResumoErroInstalacao(Arquivo);
end;

{ Bloco "primeiro acesso" da pagina final da instalacao nova. Com o aviso de banco ja configurado, mostra o aviso no
  lugar do usuario informado (que nao foi criado) - antes a tela dizia para entrar com ele. }
function BlocoPrimeiroAcesso(const Login, Email, Aviso: String): String;
begin
  if Aviso <> '' then
    Result := Aviso
  else
    Result :=
      'Primeiro acesso (administrador):' + #13#10 +
      '   Usuario: ' + Login + #13#10 +
      '   E-mail:  ' + Email + #13#10 +
      '   Senha:   a que voce definiu nesta instalacao' + #13#10#13#10 +
      'Guarde essas informacoes em local seguro.';
end;

{ Mensagem da tela de falha da configuracao final: o erro real (quando houver) e onde esta o log completo. }
function MensagemFalhaConfiguracao(Codigo: Integer; const Resumo, ArquivoLog: String): String;
begin
  Result := 'A configuracao final falhou (codigo ' + IntToStr(Codigo) + ').';
  if Resumo <> '' then
    Result := Result + #13#10#13#10 + Resumo;
  Result := Result + #13#10#13#10 + 'Log completo: ' + ArquivoLog + #13#10#13#10 + 'Abrir o log agora?';
end;

{ Erro do login (ja em minusculas) pela regra do sistema - comeca com letra, so letras minusculas sem acento, numeros
  e pontos, 3 a 30 caracteres (LOGIN_REGEX de src/scripts/onpremise-setup.ts) -, dizendo o caractere e a posicao
  do problema. '' = valido. }
function ErroLogin(const V: String): String;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(V) do
  begin
    C := V[I];
    if not (((C >= 'a') and (C <= 'z')) or ((C >= '0') and (C <= '9')) or (C = '.')) then
    begin
      Result := 'O caractere "' + C + '" (posicao ' + IntToStr(I) + ') nao e permitido no login. ' +
        'Use so letras minusculas sem acento, numeros e pontos.';
      Exit;
    end;
  end;
  if (Length(V) < 3) or (Length(V) > 30) then
    Result := 'O login precisa ter de 3 a 30 caracteres (tem ' + IntToStr(Length(V)) + ').'
  else if (V[1] < 'a') or (V[1] > 'z') then
    Result := 'O login precisa comecar com uma letra (o caractere "' + V[1] + '" na posicao 1 nao serve).';
end;

{ Login e e-mail do administrador como serao gravados. Entram como digitados; saem normalizados:
  - login em minusculas (maiusculas nao sao erro);
  - login com "@" (um e-mail): aceito se for igual ao e-mail informado, ou se o e-mail estiver vazio (vira o e-mail);
    o login passa a ser a parte antes do "@" e VeioComoEmail = True (o instalador avisa que da para entrar com os
    dois). E-mail diferente: recusa, explicando.
  Devolve '' se tudo certo, ou a mensagem de erro. }
function NormalizarLoginAdmin(var Login, Email: String; var VeioComoEmail: Boolean): String;
var
  P: Integer;
begin
  Result := '';
  VeioComoEmail := False;
  Login := Lowercase(Trim(Login));
  Email := Trim(Email);
  if Login = '' then
  begin
    Result := 'Preencha o usuario (login).';
    Exit;
  end;
  P := Pos('@', Login);
  if P > 0 then
  begin
    if (Email <> '') and (Lowercase(Email) <> Login) then
    begin
      Result := 'O login "' + Login + '" e um e-mail diferente do e-mail informado (' + Email + '). ' +
        'Use o mesmo e-mail nos dois campos (o login vira a parte antes do @) ou um login sem @.';
      Exit;
    end;
    if Email = '' then Email := Login;
    Login := Copy(Login, 1, P - 1);
    VeioComoEmail := True;
  end;
  Result := ErroLogin(Login);
  if (Result <> '') and VeioComoEmail then
    Result := 'O login seria "' + Login + '" (a parte antes do @ do e-mail). ' + Result;
end;
