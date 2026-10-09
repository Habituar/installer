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
