; e-Financeira On-Premise - instalador para Windows Server
; Requer Inno Setup 6.3+ (ArchitecturesInstallIn64BitMode=x64compatible)
; Compile pelo build.ps1, que monta a pasta "stage" antes.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifdef SemPostgres
  ; Versao sem PostgreSQL: so SQL Server ou Oracle existentes (compilar com /DSemPostgres)
  #define Sufixo "-sem-postgres"
#else
  #define Sufixo ""
#endif
#define AppName "e-Financeira On-Premise"
#define ServiceName "efinanceira-api"

[Setup]
AppId={{7C1E5A2B-3D4F-4B8A-9E61-0F2A5C8D9B34}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=ZAP Sistemas
DefaultDirName={autopf}\eFinanceira
DefaultGroupName=e-Financeira
DisableProgramGroupPage=yes
UsePreviousAppDir=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=output
OutputBaseFilename=efinanceira-onpremise-{#AppVersion}{#Sufixo}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName={#AppName}

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Tasks]
Name: "firewall"; Description: "Liberar a porta no Firewall do Windows (acesso a partir de outras maquinas da rede)"; Flags: unchecked

[Files]
Source: "stage\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
; Atualização: guarda a versão em uso em {app}\previous\ ANTES de copiar os arquivos novos (rodado no PrepareToInstall)
Source: "scripts\salvar-versao-anterior.ps1"; Flags: dontcopy
; Instalador do PostgreSQL: so e extraido na instalacao nova com banco embutido
#ifndef SemPostgres
Source: "deps\postgresql-installer.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall; Check: NeedPgInstaller
#endif

[Icons]
Name: "{group}\e-Financeira"; Filename: "{app}\e-Financeira.url"
Name: "{group}\Logs do e-Financeira"; Filename: "{app}\logs"
Name: "{group}\Voltar para a versao anterior (rollback)"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\rollback.ps1"""; WorkingDir: "{app}"; Comment: "Desfaz a ultima atualizacao (exige administrador)"

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\uninstall-services.ps1"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveServices"

[UninstallDelete]
; Dados do cliente (config, logs, pgdata, pgsql) sao preservados de proposito.
Type: filesandordirs; Name: "{app}\services"
Type: files; Name: "{app}\e-Financeira.url"

[Code]
var
  DbModePage: TInputOptionWizardPage;
  DbConnPage, AppPage, ClientePage, AdminPage: TInputQueryWizardPage;
  TestPage: TWizardPage;
  TestButton: TNewButton;
  StatusPanel, StatusBar: TPanel;
  StatusTitle, StatusDetail: TNewStaticText;
  CnpjEdit: TPasswordEdit;      { ClientePage.Edits[1] — mascara em tempo real }
  FormatandoCnpj: Boolean;      { evita reentrar no OnChange ao reescrever o Text }
  BackupPage: TInputOptionWizardPage; { atualizacao: confirmacao obrigatoria do backup do banco }

const
  ColorNeutralBg = $00F5F5F5;   { cinza bem claro: em andamento }
  ColorNeutralBar = $00C8C8C8;
  ColorOkBg    = $00ECF6E9;    { verde bem claro: sucesso }
  ColorOkBar   = $0050AF4C;
  ColorOkText  = $00327D2E;
  ColorErrBg   = $00E9EDFC;    { vermelho bem claro: falha (BGR: FCEDE9) }
  ColorErrBar  = $004747E5;
  ColorErrText = $002424C9;

function IsUpgrade: Boolean;
begin
  Result := FileExists(WizardDirValue + '\config\backend.env');
end;

{ Tipo escolhido: 0 = PostgreSQL embutido, 1 = PostgreSQL existente, 2 = SQL Server, 3 = Oracle }
function Kind: Integer;
begin
#ifdef SemPostgres
  Result := DbModePage.SelectedValueIndex + 2;
#else
  Result := DbModePage.SelectedValueIndex;
#endif
end;

function IsEmbedded: Boolean;
begin
  Result := Kind = 0;
end;

{ 'postgres' | 'mssql' | 'oracle' conforme a escolha na pagina de banco }
function DbTypeValue: String;
begin
  case Kind of
    2: Result := 'mssql';
    3: Result := 'oracle';
  else
    Result := 'postgres';
  end;
end;

function NeedPgInstaller: Boolean;
begin
  Result := (not IsUpgrade) and IsEmbedded;
end;

{ Escapa para dentro de uma string PowerShell entre aspas duplas: crase, aspas e $ (que senao
  vira interpolacao de variavel — importante para a senha, que pode ter qualquer caractere). }
function PsEscape(S: String): String;
begin
  StringChangeEx(S, '`', '``', True);
  StringChangeEx(S, '"', '`"', True);
  StringChangeEx(S, '$', '`$', True);
  Result := S;
end;

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

{ Testa a conexao com os dados preenchidos na pagina "Conexao com o banco de dados".
  SQL Server: login de verdade (System.Data.SqlClient, que ja vem no Windows) — confirma
  servidor, porta, banco, usuario e senha. PostgreSQL/Oracle existentes: so a porta TCP, porque
  o instalador ainda nao tem o driver desses bancos nesta fase (so depois de extrair os arquivos) —
  isso NAO confirma usuario, senha nem se o banco/schema existe. }
function TestarConexao: String;
var
  ps1, outFile, host, portS, db, usr, pass, script, serverPart: String;
  outContent: AnsiString;
  instancia: Boolean;
  ResultCode: Integer;
begin
  host := Trim(DbConnPage.Values[0]);
  portS := Trim(DbConnPage.Values[1]);
  db := Trim(DbConnPage.Values[2]);
  usr := Trim(DbConnPage.Values[3]);
  pass := DbConnPage.Values[4];

  { "servidor\instancia" (SQL Server): a porta fica a cargo do SQL Server Browser resolver
    sozinho, igual o SSMS faz — nao exigimos porta nesse caso, e nao mandamos porta nenhuma pro
    driver (se mandasse as duas coisas juntas, o driver pularia a resolucao por nome e tentaria
    ir direto numa porta que quase certamente nao e a real, dando timeout). }
  instancia := (Kind = 2) and (Pos('\', host) > 0);

  if (host = '') or ((portS = '') and not instancia) then
  begin
    Result := 'Preencha ao menos servidor e porta antes de testar.';
    Exit;
  end;

  ps1 := ExpandConstant('{tmp}\efin-test-conn.ps1');
  outFile := ExpandConstant('{tmp}\efin-test-conn.txt');
  DeleteFile(outFile);

  if Kind = 2 then
  begin
    { SQL Server: mesmas opcoes (Encrypt/TrustServerCertificate) que o backend usa depois (ver
      postinstall.ps1, DB_ENCRYPT/DB_TRUST_CERT). }
    if instancia then
      serverPart := PsEscape(host)   { "servidor\instancia", sem porta }
    else
      serverPart := PsEscape(host) + ',' + portS;
    script :=
      'try {' + #13#10 +
      '  Add-Type -AssemblyName System.Data' + #13#10 +
      '  $cs = "Server=' + serverPart + ';Database=' + PsEscape(db) +
        ';User Id=' + PsEscape(usr) + ';Password=' + PsEscape(pass) +
        ';Encrypt=True;TrustServerCertificate=True;Connection Timeout=6;"' + #13#10 +
      '  $conn = New-Object System.Data.SqlClient.SqlConnection($cs)' + #13#10 +
      '  $conn.Open()' + #13#10 +
      '  $conn.Close()' + #13#10 +
      '  "OK: conectou e autenticou em ' + host + ', banco ' + db + '." | Out-File -Encoding utf8 "' + outFile + '"' + #13#10 +
      '} catch {' + #13#10 +
      '  "ERRO: " + $_.Exception.Message | Out-File -Encoding utf8 "' + outFile + '"' + #13#10 +
      '}';
  end
  else
  begin
    { PostgreSQL ou Oracle existentes: so confirma que algo responde na porta. }
    script :=
      'try {' + #13#10 +
      '  $c = New-Object Net.Sockets.TcpClient' + #13#10 +
      '  $iar = $c.BeginConnect("' + PsEscape(host) + '", ' + portS + ', $null, $null)' + #13#10 +
      '  if ($iar.AsyncWaitHandle.WaitOne(5000) -and $c.Connected) {' + #13#10 +
      '    "OK: a porta ' + portS + ' respondeu em ' + host + '. (Isso nao confirma usuario, senha nem o banco/schema — so que o servidor esta ligado e alcancavel.)" | Out-File -Encoding utf8 "' + outFile + '"' + #13#10 +
      '  } else {' + #13#10 +
      '    "ERRO: sem resposta em ' + host + ':' + portS + '. Confira servidor, porta e firewall." | Out-File -Encoding utf8 "' + outFile + '"' + #13#10 +
      '  }' + #13#10 +
      '  $c.Close()' + #13#10 +
      '} catch {' + #13#10 +
      '  "ERRO: " + $_.Exception.Message | Out-File -Encoding utf8 "' + outFile + '"' + #13#10 +
      '}';
  end;

  SaveStringToFile(ps1, script, False);

  if not Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -File "' + ps1 + '"', '',
     SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    Result := 'Nao consegui rodar o teste (powershell.exe nao encontrado).';
    Exit;
  end;

  { LoadStringFromFile so existe para AnsiString (bytes crus); Utf8Decode converte esses bytes
    pra Unicode de verdade, em vez do cast ingenuo String(outContent) que causava o texto cagado
    tipo "ExceÃ§Ã£o" no lugar de "Exceção". }
  if LoadStringFromFile(outFile, outContent) then
    Result := Trim(Utf8Decode(outContent))
  else
    Result := 'Sem resposta do teste (codigo ' + IntToStr(ResultCode) + ').';

  DeleteFile(ps1);
  DeleteFile(outFile);
end;

procedure TestarConexaoClick(Sender: TObject);
var
  Msg, Detail: String;
begin
  TestButton.Enabled := False;

  StatusPanel.Color := ColorNeutralBg;
  StatusBar.Color := ColorNeutralBar;
  StatusTitle.Font.Color := clWindowText;
  StatusTitle.Caption := 'Testando conexao...';
  StatusDetail.Caption := 'Pode levar ate 5-6 segundos.';
  StatusDetail.AdjustHeight;
  StatusPanel.Height := StatusDetail.Top + StatusDetail.Height + ScaleY(12);
  StatusBar.Height := StatusPanel.Height;
  StatusPanel.Visible := True;
  StatusPanel.Repaint;
  StatusTitle.Repaint;
  StatusDetail.Repaint;

  Msg := TestarConexao;

  { Tira o prefixo "OK: " / "ERRO: " da mensagem tecnica: ele vira o titulo do card,
    o resto do texto (com o motivo/detalhe) fica como corpo. }
  if Pos('OK:', Msg) = 1 then
  begin
    Detail := Trim(Copy(Msg, Length('OK:') + 1, MaxInt));
    StatusPanel.Color := ColorOkBg;
    StatusBar.Color := ColorOkBar;
    StatusTitle.Font.Color := ColorOkText;
    StatusTitle.Caption := 'Conexao OK';
  end
  else
  begin
    if Pos('ERRO:', Msg) = 1 then
      Detail := Trim(Copy(Msg, Length('ERRO:') + 1, MaxInt))
    else
      Detail := Msg;
    StatusPanel.Color := ColorErrBg;
    StatusBar.Color := ColorErrBar;
    StatusTitle.Font.Color := ColorErrText;
    StatusTitle.Caption := 'Falha na conexao';
  end;
  StatusDetail.Caption := Detail;
  StatusDetail.AdjustHeight;
  StatusPanel.Height := StatusDetail.Top + StatusDetail.Height + ScaleY(12);
  StatusBar.Height := StatusPanel.Height;
  TestButton.Enabled := True;
end;

function LimpaCnpj(S: String): String;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  S := Uppercase(S);
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if ((C >= '0') and (C <= '9')) or ((C >= 'A') and (C <= 'Z')) then
      Result := Result + C;
  end;
end;

{ Digito verificador (modulo 11, CNPJ alfanumerico: valor = ASCII - 48) sobre os N primeiros caracteres }
function DvCnpj(const S: String; N: Integer): Integer;
var
  I, Soma, Peso: Integer;
begin
  Soma := 0;
  Peso := 2;
  for I := N downto 1 do
  begin
    Soma := Soma + (Ord(S[I]) - 48) * Peso;
    Peso := Peso + 1;
    if Peso > 9 then Peso := 2;
  end;
  Soma := Soma mod 11;
  if Soma < 2 then Result := 0 else Result := 11 - Soma;
end;

function CnpjValido(V: String): Boolean;
var
  S: String;
  I: Integer;
  Igual: Boolean;
begin
  Result := False;
  S := LimpaCnpj(V);
  if Length(S) <> 14 then Exit;
  if (S[13] < '0') or (S[13] > '9') or (S[14] < '0') or (S[14] > '9') then Exit;
  Igual := True;
  for I := 2 to 14 do
    if S[I] <> S[1] then Igual := False;
  if Igual then Exit;
  Result := (DvCnpj(S, 12) = Ord(S[13]) - 48) and (DvCnpj(S, 13) = Ord(S[14]) - 48);
end;

{ Mascara parcial XX.XXX.XXX/XXXX-XX para o texto sendo digitado: maiusculas, A-Z/0-9 nas 12
  primeiras posicoes, so 0-9 nos 2 digitos verificadores, no maximo 14; o resto e descartado.
  Pontuacao so entra antes de um caractere ja digitado (nada sobrando no fim). }
function FormataCnpjParcial(S: String): String;
var
  I: Integer;
  C: Char;
  Raw: String;
begin
  Raw := '';
  S := Uppercase(S);
  for I := 1 to Length(S) do
  begin
    if Length(Raw) >= 14 then Break;
    C := S[I];
    if ((C >= '0') and (C <= '9')) or ((Length(Raw) < 12) and (C >= 'A') and (C <= 'Z')) then
      Raw := Raw + C;
  end;
  Result := '';
  for I := 1 to Length(Raw) do
  begin
    if (I = 3) or (I = 6) then Result := Result + '.'
    else if I = 9 then Result := Result + '/'
    else if I = 13 then Result := Result + '-';
    Result := Result + Raw[I];
  end;
end;

procedure CnpjEditChange(Sender: TObject);
var
  Novo: String;
begin
  if FormatandoCnpj then Exit;
  Novo := FormataCnpjParcial(CnpjEdit.Text);
  if Novo = CnpjEdit.Text then Exit;   { nada a corrigir: nao mexe no cursor }
  FormatandoCnpj := True;
  try
    CnpjEdit.Text := Novo;
    CnpjEdit.SelStart := Length(Novo);   { compromisso: cursor vai para o fim apos reformatar }
  finally
    FormatandoCnpj := False;
  end;
end;

procedure InitializeWizard;
begin
  DbModePage := CreateInputOptionPage(wpSelectDir, 'Banco de dados',
    'Onde ficara o banco de dados do e-Financeira?',
    'Escolha uma das opcoes abaixo.', True, False);
#ifndef SemPostgres
  DbModePage.Add('Instalar um PostgreSQL novo junto com o e-Financeira (recomendado)');
  DbModePage.Add('Usar um PostgreSQL ja existente (o banco precisa estar criado)');
#endif
  DbModePage.Add('Usar um SQL Server existente (o banco precisa estar criado)');
  DbModePage.Add('Usar um Oracle existente (o usuario/schema precisa estar criado)');
  DbModePage.SelectedValueIndex := 0;

  DbConnPage := CreateInputQueryPage(DbModePage.ID, 'Conexao com o banco de dados',
    'Informe os dados do banco existente.', 'O banco (ou schema, no Oracle) e o usuario precisam ter sido criados antes, com permissao para criar tabelas.');
  DbConnPage.Add('Servidor (host):', False);
  DbConnPage.Add('Porta:', False);
  DbConnPage.Add('Banco de dados:', False);
  DbConnPage.Add('Usuario:', False);
  DbConnPage.Add('Senha:', True);
  DbConnPage.Values[0] := 'localhost';
  DbConnPage.Values[1] := '5432';
  DbConnPage.Values[2] := 'efinanceira';

  { Pagina propria para o teste de conexao (em vez de um botao espremido na pagina de conexao,
    que ja tem 5 campos e pode nao sobrar espaco dependendo do tamanho de fonte do Windows). Fica
    praticamente vazia, entao o botao e o resultado sempre cabem, em qualquer escala de tela. }
  TestPage := CreateCustomPage(DbConnPage.ID, 'Testar conexao',
    'Confirme que o e-Financeira consegue falar com o banco antes de continuar (opcional).');

  TestButton := TNewButton.Create(WizardForm);
  TestButton.Parent := TestPage.Surface;
  TestButton.Left := 0;
  TestButton.Top := 0;
  TestButton.Width := ScaleX(160);
  TestButton.Height := ScaleY(23);
  TestButton.Caption := 'Testar conexao';
  TestButton.OnClick := @TestarConexaoClick;

  { Card de resultado: uma faixa colorida (StatusBar) + um painel (StatusPanel) com titulo em
    negrito (StatusTitle) e o detalhe (StatusDetail), em vez de uma linha de texto solta. Cinza
    "testando" / verde "conectou" / vermelho "falhou", parecido com o que a maioria dos apps
    modernos usa para feedback de status. Some ate o primeiro teste. }
  StatusPanel := TPanel.Create(WizardForm);
  StatusPanel.Parent := TestPage.Surface;
  StatusPanel.Left := 0;
  StatusPanel.Top := TestButton.Top + TestButton.Height + ScaleY(16);
  StatusPanel.Width := TestPage.Surface.Width;
  StatusPanel.Height := ScaleY(64);
  StatusPanel.BevelOuter := bvNone;
  StatusPanel.Color := ColorNeutralBg;
  StatusPanel.Visible := False;

  { Faixa solida de 4px na borda esquerda (cor do status); um TBevel so desenharia uma linha
    "entalhada", entao usamos outro TPanel fino. }
  StatusBar := TPanel.Create(WizardForm);
  StatusBar.Parent := StatusPanel;
  StatusBar.Left := 0;
  StatusBar.Top := 0;
  StatusBar.Width := ScaleX(4);
  StatusBar.Height := StatusPanel.Height;
  StatusBar.BevelOuter := bvNone;
  StatusBar.Color := ColorNeutralBar;

  StatusTitle := TNewStaticText.Create(WizardForm);
  StatusTitle.Parent := StatusPanel;
  StatusTitle.Left := ScaleX(16);
  StatusTitle.Top := ScaleY(10);
  StatusTitle.AutoSize := True;
  StatusTitle.Font.Style := [fsBold];

  StatusDetail := TNewStaticText.Create(WizardForm);
  StatusDetail.Parent := StatusPanel;
  StatusDetail.Left := ScaleX(16);
  StatusDetail.Top := StatusTitle.Top + ScaleY(20);
  StatusDetail.Width := StatusPanel.Width - ScaleX(32);
  StatusDetail.AutoSize := False;
  StatusDetail.WordWrap := True;
  StatusDetail.Caption := '';

  AppPage := CreateInputQueryPage(TestPage.ID, 'Servidor da aplicacao',
    'Em qual porta o e-Financeira vai responder?', 'Acesso pelo navegador: http://servidor:PORTA');
  AppPage.Add('Porta HTTP:', False);
  AppPage.Values[0] := '3001';

  { Dividida em duas paginas (instituicao / administrador) de proposito: com os 6 campos numa
    pagina so, em telas com escala de fonte alta (125%/150%) o ultimo campo pode sair cortado
    embaixo da janela. Com 2 campos cada, cabe em qualquer escala. }
  ClientePage := CreateInputQueryPage(AppPage.ID, 'Instituicao',
    'CNPJ da instituicao — a licenca sera vinculada a ele.', '');
  ClientePage.Add('Razao social:', False);
  ClientePage.Add('CNPJ:', False);
  CnpjEdit := ClientePage.Edits[1];
  { Sem MaxLength de proposito: o Windows cortaria um CNPJ colado com espacos em volta ANTES do
    OnChange (" 11.222.333/0001-81 " virava "...0001-8"). O limite de 18 (XX.XXX.XXX/XXXX-XX) ja
    e garantido pelo CnpjEditChange, que descarta tudo apos o 14o alfanumerico. }
  CnpjEdit.OnChange := @CnpjEditChange;

  AdminPage := CreateInputQueryPage(ClientePage.ID, 'Administrador',
    'Primeiro usuario do sistema, com acesso total.', '');
  AdminPage.Add('Nome do administrador:', False);
  AdminPage.Add('Usuario (login):', False);
  AdminPage.Add('E-mail:', False);
  AdminPage.Add('Senha (minimo 8 caracteres):', True);
  AdminPage.Add('Confirmar senha:', True);

  { So na atualizacao: a nova versao aplica alteracoes no banco (migrations). O rollback (scripts\rollback.ps1)
    desfaz as migrations novas, mas o backup e a garantia final. }
  BackupPage := CreateInputOptionPage(wpSelectDir, 'Backup antes da atualizacao',
    'Confirme o backup do banco de dados do e-Financeira',
    'Esta atualizacao aplica alteracoes no banco de dados. Faca o backup do banco ANTES de continuar.' + #13#10#13#10 +
    'A versao instalada sera guardada na pasta "previous" e podera ser restaurada pelo atalho' + #13#10 +
    '"Voltar para a versao anterior (rollback)" no menu Iniciar.', False, False);
  BackupPage.Add('Confirmo que fiz o backup do banco de dados do e-Financeira');
end;

{ Mesma regra aceita pelo backend (loginSchema em src/routes/auth.ts): comeca com letra minuscula,
  só letras minusculas/numeros/pontos, 3 a 30 caracteres. }
function LoginValido(V: String): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := False;
  if (Length(V) < 3) or (Length(V) > 30) then Exit;
  if (V[1] < 'a') or (V[1] > 'z') then Exit;
  for I := 1 to Length(V) do
  begin
    C := V[I];
    if not (((C >= 'a') and (C <= 'z')) or ((C >= '0') and (C <= '9')) or (C = '.')) then Exit;
  end;
  Result := True;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if PageID = BackupPage.ID then
  begin
    Result := not IsUpgrade; { instalacao nova: nao ha banco para guardar }
    Exit;
  end;
  { Em atualizacao, nada e perguntado: config e banco existentes sao mantidos }
  if IsUpgrade and ((PageID = DbModePage.ID) or (PageID = DbConnPage.ID) or (PageID = TestPage.ID) or
                    (PageID = AppPage.ID) or (PageID = ClientePage.ID) or (PageID = AdminPage.ID)) then
    Result := True
  else if (PageID = DbConnPage.ID) or (PageID = TestPage.ID) then
    Result := IsEmbedded;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  P: Integer;
begin
  Result := True;
  if (CurPageID = BackupPage.ID) and (not BackupPage.Values[0]) then
  begin
    MsgBox('Faca o backup do banco de dados e marque a confirmacao para continuar a atualizacao.', mbError, MB_OK);
    Result := False;
    Exit;
  end;
  if CurPageID = DbModePage.ID then
  begin
    StatusPanel.Visible := False; { limpa o resultado de um teste anterior (pode ser outro tipo de banco) }
    case Kind of
      2: begin
           DbConnPage.PromptLabels[2].Caption := 'Banco de dados (database):';
           DbConnPage.Values[1] := '1433';
           DbConnPage.Values[2] := 'efinanceira';
         end;
      3: begin
           DbConnPage.PromptLabels[2].Caption := 'Service name do Oracle:';
           DbConnPage.Values[1] := '1521';
           DbConnPage.Values[2] := 'ORCLPDB1';
         end;
    else
      begin
        DbConnPage.PromptLabels[2].Caption := 'Banco de dados:';
        DbConnPage.Values[1] := '5432';
        DbConnPage.Values[2] := 'efinanceira';
      end;
    end;
  end
  else if CurPageID = DbConnPage.ID then
  begin
    P := StrToIntDef(DbConnPage.Values[1], 0);
    { "servidor\instancia" do SQL Server: a porta e resolvida sozinha pelo SQL Server Browser
      (igual SSMS), entao nao exigimos ela preenchida nesse caso. }
    if (Trim(DbConnPage.Values[0]) = '') or (Trim(DbConnPage.Values[2]) = '') or
       (Trim(DbConnPage.Values[3]) = '') or
       (((P < 1) or (P > 65535)) and not ((Kind = 2) and (Pos('\', DbConnPage.Values[0]) > 0))) then
    begin
      MsgBox('Preencha servidor, porta valida, banco e usuario.', mbError, MB_OK);
      Result := False;
    end
    else
      StatusPanel.Visible := False; { indo para a pagina de teste: limpa resultado de um teste anterior }
  end
  else if CurPageID = AppPage.ID then
  begin
    P := StrToIntDef(AppPage.Values[0], 0);
    if (P < 1) or (P > 65535) then
    begin
      MsgBox('Informe uma porta valida (1 a 65535).', mbError, MB_OK);
      Result := False;
    end;
  end
  else if CurPageID = ClientePage.ID then
  begin
    if Trim(ClientePage.Values[0]) = '' then
    begin
      MsgBox('Preencha a razao social.', mbError, MB_OK);
      Result := False;
    end
    else if not CnpjValido(ClientePage.Values[1]) then
    begin
      MsgBox('CNPJ invalido. Confira os 14 caracteres (a licenca so funciona para este CNPJ).', mbError, MB_OK);
      Result := False;
    end;
  end
  else if CurPageID = AdminPage.ID then
  begin
    if Trim(AdminPage.Values[0]) = '' then
    begin
      MsgBox('Preencha o nome do administrador.', mbError, MB_OK);
      Result := False;
    end
    else if not LoginValido(Trim(AdminPage.Values[1])) then
    begin
      MsgBox('Usuario invalido: comece com letra minuscula e use apenas letras minusculas, numeros e pontos (3 a 30 caracteres).', mbError, MB_OK);
      Result := False;
    end
    else if Pos('@', AdminPage.Values[2]) < 2 then
    begin
      MsgBox('Informe um e-mail valido.', mbError, MB_OK);
      Result := False;
    end
    else if Length(AdminPage.Values[3]) < 8 then
    begin
      MsgBox('A senha precisa ter pelo menos 8 caracteres.', mbError, MB_OK);
      Result := False;
    end
    else if AdminPage.Values[3] <> AdminPage.Values[4] then
    begin
      MsgBox('A confirmacao de senha nao confere.', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

{ Porta HTTP realmente em uso: le config\backend.env (ja escrito pelo postinstall.ps1 a essa
  altura, tanto em instalacao nova quanto em atualizacao) em vez de confiar em AppPage.Values[0],
  que na atualizacao nem chega a ser perguntado de novo (pagina pulada = fica com o valor padrao,
  nao com a porta configurada na instalacao original). }
function GetInstalledPort: String;
var
  Lines: TArrayOfString;
  I: Integer;
begin
  Result := Trim(AppPage.Values[0]);
  if LoadStringsFromFile(ExpandConstant('{app}\config\backend.env'), Lines) then
  begin
    for I := 0 to GetArrayLength(Lines) - 1 do
    begin
      if Pos('PORT=', Lines[I]) = 1 then
      begin
        Result := Trim(Copy(Lines[I], Length('PORT=') + 1, MaxInt));
        Break;
      end;
    end;
  end;
end;

{ Tela final (wpFinished): em vez do texto generico do Inno, mostra o que a pessoa realmente
  precisa para o primeiro acesso — URL, usuario e e-mail do administrador. Numa atualizacao,
  nada foi criado de novo, entao so confirma a URL e lembra que o login continua o mesmo. }
procedure CurPageChanged(CurPageID: Integer);
var
  Porta, Url, Msg: String;
begin
  if CurPageID <> wpFinished then Exit;

  Porta := GetInstalledPort;
  Url := 'http://localhost:' + Porta;

  if IsUpgrade then
  begin
    Msg :=
      'O e-Financeira foi atualizado e ja esta em execucao.' + #13#10#13#10 +
      'Acesse pelo navegador em:' + #13#10 +
      '   ' + Url + #13#10#13#10 +
      'O usuario e a senha de acesso continuam os mesmos de antes.';
  end
  else
  begin
    Msg :=
      'O e-Financeira foi instalado e ja esta em execucao.' + #13#10#13#10 +
      'Acesse pelo navegador em:' + #13#10 +
      '   ' + Url;
    if WizardIsTaskSelected('firewall') and (GetEnv('COMPUTERNAME') <> '') then
      Msg := Msg + #13#10 +
        '   (de outros computadores da rede: http://' + GetEnv('COMPUTERNAME') + ':' + Porta + ')';
    Msg := Msg + #13#10#13#10 +
      'Primeiro acesso (administrador):' + #13#10 +
      '   Usuario: ' + Trim(AdminPage.Values[1]) + #13#10 +
      '   E-mail:  ' + Trim(AdminPage.Values[2]) + #13#10 +
      '   Senha:   a que voce definiu nesta instalacao' + #13#10#13#10 +
      'Guarde essas informacoes em local seguro. O atalho "e-Financeira" foi criado no menu Iniciar.';
  end;

  WizardForm.FinishedLabel.AutoSize := False;
  WizardForm.FinishedLabel.WordWrap := True;
  WizardForm.FinishedLabel.Caption := Msg;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  RC: Integer;
begin
  { Atualizacao: para o servico para liberar os arquivos }
  Exec(ExpandConstant('{sys}\sc.exe'), 'stop {#ServiceName}', '', SW_HIDE, ewWaitUntilTerminated, RC);
  Sleep(4000);
  Result := '';
  { ... e guarda a versao em uso em <app>\previous (o rollback.ps1 restaura dali). Falhou: cancela a atualizacao
    antes de qualquer arquivo ser trocado, e o servico volta a subir. }
  if IsUpgrade then
  begin
    ExtractTemporaryFile('salvar-versao-anterior.ps1');
    if (not Exec('powershell.exe',
          '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\salvar-versao-anterior.ps1') + '" -App "' + WizardDirValue + '"',
          '', SW_HIDE, ewWaitUntilTerminated, RC)) or (RC <> 0) then
    begin
      Exec(ExpandConstant('{sys}\sc.exe'), 'start {#ServiceName}', '', SW_HIDE, ewWaitUntilTerminated, RC);
      Result := 'Nao foi possivel guardar a versao instalada em "previous" (codigo ' + IntToStr(RC) + '). ' +
        'A atualizacao foi cancelada e nada foi alterado. Verifique o espaco em disco e as permissoes da pasta.';
    end;
  end;
end;

function J(S: String): String;
begin
  StringChangeEx(S, '\', '\\', True);
  StringChangeEx(S, '"', '\"', True);
  Result := S;
end;

function B(V: Boolean): String;
begin
  if V then Result := 'true' else Result := 'false';
end;

procedure WriteParams;
var
  Lines: TArrayOfString;
  Mode: String;
begin
  if IsEmbedded then Mode := 'embedded' else Mode := 'existing';
  ForceDirectories(ExpandConstant('{app}\config'));
  SetArrayLength(Lines, 1);
  Lines[0] := '{' +
    '"dbMode":"' + Mode + '",' +
    '"dbType":"' + DbTypeValue + '",' +
    '"pgInstaller":"' + J(ExpandConstant('{tmp}\postgresql-installer.exe')) + '",' +
    '"dbHost":"' + J(Trim(DbConnPage.Values[0])) + '",' +
    '"dbPort":"' + J(Trim(DbConnPage.Values[1])) + '",' +
    '"dbName":"' + J(Trim(DbConnPage.Values[2])) + '",' +
    '"dbUser":"' + J(Trim(DbConnPage.Values[3])) + '",' +
    '"dbPassword":"' + J(DbConnPage.Values[4]) + '",' +
    '"httpPort":"' + J(Trim(AppPage.Values[0])) + '",' +
    '"clienteNome":"' + J(Trim(ClientePage.Values[0])) + '",' +
    '"clienteCnpj":"' + J(LimpaCnpj(ClientePage.Values[1])) + '",' +
    '"adminNome":"' + J(Trim(AdminPage.Values[0])) + '",' +
    '"adminLogin":"' + J(Trim(AdminPage.Values[1])) + '",' +
    '"adminEmail":"' + J(Trim(AdminPage.Values[2])) + '",' +
    '"adminSenha":"' + J(AdminPage.Values[3]) + '",' +
    '"firewall":' + B(WizardIsTaskSelected('firewall')) +
    '}';
  SaveStringsToUTF8File(ExpandConstant('{app}\config\install-params.json'), Lines, False);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  RC: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    WriteParams;
    WizardForm.StatusLabel.Caption := 'Configurando banco de dados e servicos (pode levar alguns minutos)...';
    if (not Exec('powershell.exe',
          '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\scripts\postinstall.ps1') + '"',
          ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, RC)) or (RC <> 0) then
      MsgBox('A configuracao final falhou (codigo ' + IntToStr(RC) + ').' + #13#10 +
             'Veja o log em: ' + ExpandConstant('{app}\logs\install.log'), mbError, MB_OK);
  end;
end;
