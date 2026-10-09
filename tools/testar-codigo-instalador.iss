; Teste do codigo Pascal REAL do instalador (codigo-comum.iss). Nao instala nada: InitializeSetup grava o resultado
; de cada verificacao ("ok ..." ou "FALHA ...") no arquivo de /saida= e devolve False.
; Rodar pelo tools\testar-codigo-instalador.ps1 (compila com o ISCC numa pasta temporaria e executa).
[Setup]
AppName=Teste codigo instalador e-Financeira
AppVersion=1
CreateAppDir=no
PrivilegesRequired=lowest
Uninstallable=no
OutputBaseFilename=testar-codigo-instalador

[Code]
#include "..\codigo-comum.iss"

var
  Saida: TArrayOfString;

procedure Registra(Ok: Boolean; const Texto: String);
var
  N: Integer;
begin
  N := GetArrayLength(Saida);
  SetArrayLength(Saida, N + 1);
  if Ok then Saida[N] := 'ok    ' + Texto else Saida[N] := 'FALHA ' + Texto;
end;

{ Item 4: login do administrador }
procedure Login(const Digitado, EmailDigitado, LoginEsperado, EmailEsperado: String; ComoEmail: Boolean; const TrechoErro: String);
var
  L, E, Erro: String;
  V: Boolean;
begin
  L := Digitado;
  E := EmailDigitado;
  Erro := NormalizarLoginAdmin(L, E, V);
  if TrechoErro = '' then
    Registra((Erro = '') and (L = LoginEsperado) and (E = EmailEsperado) and (V = ComoEmail),
      'login "' + Digitado + '" / e-mail "' + EmailDigitado + '" -> "' + L + '" / "' + E + '"' + ' erro=[' + Erro + ']')
  else
    Registra(Pos(TrechoErro, Erro) > 0, 'login "' + Digitado + '" recusado com [' + TrechoErro + ']: [' + Erro + ']');
end;

function InitializeSetup(): Boolean;
begin
  SetArrayLength(Saida, 0);

  Login('Wesdras.Alves', 'wesdras.alves@zapsistemas.com.br', 'wesdras.alves', 'wesdras.alves@zapsistemas.com.br', False, '');
  Login('  admin  ', 'a@b.com', 'admin', 'a@b.com', False, '');
  Login('wesdras.alves@zapsistemas.com.br', 'wesdras.alves@zapsistemas.com.br', 'wesdras.alves', 'wesdras.alves@zapsistemas.com.br', True, '');
  Login('Wesdras.Alves@ZapSistemas.com.br', 'wesdras.alves@zapsistemas.com.br', 'wesdras.alves', 'wesdras.alves@zapsistemas.com.br', True, '');
  Login('wesdras.alves@zapsistemas.com.br', '', 'wesdras.alves', 'wesdras.alves@zapsistemas.com.br', True, '');
  Login('outro@zapsistemas.com.br', 'wesdras.alves@zapsistemas.com.br', '', '', False, 'diferente do e-mail informado');
  Login('joao_silva', 'j@x.com', '', '', False, 'O caractere "_" (posicao 5)');
  Login('joão', 'j@x.com', '', '', False, 'O caractere "' + #$00E3 + '" (posicao 3)');
  Login('joao silva', 'j@x.com', '', '', False, 'O caractere " " (posicao 5)');
  Login('ab', 'j@x.com', '', '', False, 'de 3 a 30 caracteres (tem 2)');
  Login('1abc', 'j@x.com', '', '', False, 'comecar com uma letra');
  Login('john-doe@x.com', 'john-doe@x.com', '', '', False, 'O login seria "john-doe"');
  Login('john-doe@x.com', 'john-doe@x.com', '', '', False, 'O caractere "-" (posicao 5)');
  Login('', 'j@x.com', '', '', False, 'Preencha o usuario');

  { Item 1: banco ja configurado - a pagina final mostra o aviso, nao o usuario que nao foi criado }
  Registra(Pos('Usuario: admin', BlocoPrimeiroAcesso('admin', 'a@b.com', '')) > 0, 'sem aviso: pagina final mostra o administrador criado');
  Registra((BlocoPrimeiroAcesso('admin', 'a@b.com', 'Banco ja configurado: o administrador informado NAO foi criado.') =
    'Banco ja configurado: o administrador informado NAO foi criado.'), 'com aviso: pagina final mostra o aviso no lugar do usuario descartado');
  Registra(LerAvisoInstalacao(ExpandConstant('{param:aviso|}')) = 'Banco já configurado: o administrador informado NÃO foi criado.' + #13#10 + 'Instituição: Teste',
    'install-aviso.txt (UTF-8 com BOM, acentos) lido como o setup gravou');
  Registra(LerAvisoInstalacao(ExpandConstant('{param:aviso|}') + '.nao-existe') = '', 'sem install-aviso.txt: sem aviso');

  SaveStringsToUTF8File(ExpandConstant('{param:saida|}'), Saida, False);
  Result := False;
end;
