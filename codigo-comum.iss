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
