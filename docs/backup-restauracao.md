# Backup, atualização e restauração — e-Financeira On-Premise

Procedimento para quem administra o servidor: backup antes de atualizar, conferência depois da atualização e como
voltar atrás. Os comandos abaixo usam os valores de uma instalação típica; troque pelos da sua:

| O quê | Exemplo | Onde conferir |
|---|---|---|
| Pasta da instalação | `C:\Program Files\eFinanceira` | menu Iniciar → "Logs do e-Financeira" (a pasta acima de `logs`) |
| Instância do SQL Server | `.\SQLEXPRESS` | `config\backend.env` (`DB_HOST`) ou o SQL Server Configuration Manager |
| Banco | `efinanceira` | `config\backend.env` (`DB_NAME`) |
| Porta do e-Financeira | `3008` | `config\backend.env` (`PORT`) |

> **O backup do banco de dados é responsabilidade do cliente.** O e-Financeira não faz backup do banco sozinho. A
> instalação guarda só a versão anterior dos *programas* (pasta `previous\`, para o rollback); os *dados* estão no
> banco, e só o backup do banco os protege. Mantenha a rotina de backup da instituição e faça um backup extra antes
> de toda atualização.

> **A pasta `config\` só funciona na mesma máquina.** As senhas e chaves do `config\backend.env` são cifradas com o
> DPAPI do Windows (escopo da máquina): só o servidor que as gravou consegue lê-las. A cópia de `config\` serve para
> restaurar **neste mesmo servidor**. Em outro servidor, a instalação precisa ser feita de novo (instalação nova
> apontando para o banco restaurado) e o certificado digital da instituição cadastrado outra vez.

## 1. Antes de atualizar: backup

Num PowerShell. O usuário do Windows precisa ser administrador da instância do SQL Server (`sysadmin`).

```powershell
$inst = '.\SQLEXPRESS'                  # instância do SQL Server
$app  = 'C:\Program Files\eFinanceira'  # pasta da instalação
$dest = "C:\backup-efinanceira\$(Get-Date -Format 'yyyy-MM-dd')-antes-da-atualizacao"
New-Item -ItemType Directory -Force $dest | Out-Null

# O SQL Server grava o .bak com a conta do serviço dele: libere a pasta para ela (troque pelo nome da sua instância;
# na instância padrão, NT Service\MSSQLSERVER)
icacls $dest /grant 'NT Service\MSSQL$SQLEXPRESS:(OI)(CI)M'

sqlcmd -S $inst -E -b -Q "BACKUP DATABASE [efinanceira] TO DISK = N'$dest\efinanceira.bak' WITH COPY_ONLY, CHECKSUM, INIT, STATS = 10"
sqlcmd -S $inst -E -b -Q "RESTORE VERIFYONLY FROM DISK = N'$dest\efinanceira.bak' WITH CHECKSUM"
sqlcmd -S $inst -E -d efinanceira -Q "SELECT name FROM typeorm_migrations ORDER BY timestamp" -o "$dest\migrations-antes.txt"

# config\ (backend.env, certificados da RFB); códigos de saída 0 a 7 do robocopy = sucesso
robocopy "$app\config" "$dest\config" /E /COPY:DAT /DCOPY:T /R:1 /W:1

# o instalador da versão em uso, para poder reinstalá-la
Copy-Item '<pasta onde está o instalador atual>\efinanceira-onpremise-<versão>-setup.exe' $dest
Get-FileHash "$dest\efinanceira.bak", "$dest\*.exe" | Format-List
```

- `COPY_ONLY` não interfere na sequência de backups que a instituição já faz.
- Se o `robocopy` responder "Acesso negado", rode essa linha num PowerShell **como administrador**.
- PostgreSQL embutido: use `pg_dump` da pasta `pgsql\bin` da instalação (`pg_dump -h 127.0.0.1 -p <porta> -U
  efinanceira -Fc -f "$dest\efinanceira.dump" efinanceira`). Oracle: o procedimento de backup do DBA (Data Pump ou
  RMAN).

## 2. Depois de atualizar: as migrations rodaram?

Na atualização, as alterações do banco (migrations) rodam quando o serviço inicia, **antes** de ele abrir a porta.
Por isso "e-Financeira no ar" no `install.log` já indica que elas rodaram sem erro.

```powershell
$logs = "$app\logs"
Select-String "$logs\install.log" -Pattern 'e-Financeira no ar|Migration .* failed|FATAL' | Select-Object -Last 5
Get-Item "$logs\install-erro.txt" -ErrorAction SilentlyContinue        # só existe (com data de hoje) se a atualização falhou
Select-String "$logs\efinanceira-api.out.log" -Pattern 'Migrations aplicadas' | Select-Object -Last 3
Select-String "$logs\efinanceira-api.err.log" -Pattern 'Migration|QueryFailedError|FATAL' | Select-Object -Last 10
sqlcmd -S $inst -E -d efinanceira -Q "SELECT TOP 5 name FROM typeorm_migrations ORDER BY timestamp DESC"
Invoke-RestMethod http://localhost:3008/health                         # "versao" = a versão nova
```

Compare `typeorm_migrations` com o `migrations-antes.txt`: as linhas novas são as migrations da versão instalada.

## 3. Se algo der errado: voltar atrás

### 3.1 Rollback (primeira opção)

Quando a versão nova sobe mas tem um problema de funcionamento. Menu Iniciar → **"Voltar para a versão anterior
(rollback)"** (pede administrador). Ele:

1. para o serviço;
2. desfaz no banco só as migrations que a versão anterior não conhece;
3. troca os programas pelos da pasta `previous\` (a versão desfeita fica em `desfeita-<data>\`);
4. sobe o serviço e confere o `/health`.

O rollback **não mexe em `config\`**. Se a atualização alterou o `backend.env` (por exemplo, a 1.2.28 retira dele o
`CERT_SERVIDOR_RFB`), copie de volta o `backend.env` do backup e reinicie o serviço — num PowerShell **como
administrador**:

```powershell
Copy-Item "$dest\config\backend.env" "$app\config\backend.env" -Force
Restart-Service efinanceira-api
```

### 3.2 Restaurar o backup e reinstalar a versão anterior

Quando as migrations falharam no meio, o rollback falhou ou os dados ficaram danificados. Num PowerShell **como
administrador**:

```powershell
Stop-Service efinanceira-api
sqlcmd -S $inst -E -b -Q "ALTER DATABASE [efinanceira] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; RESTORE DATABASE [efinanceira] FROM DISK = N'$dest\efinanceira.bak' WITH REPLACE, CHECKSUM; ALTER DATABASE [efinanceira] SET MULTI_USER;"
robocopy "$dest\config" "$app\config" /E /COPY:DAT /R:1 /W:1
& "$dest\efinanceira-onpremise-<versão anterior>-setup.exe"   # instala por cima, como atualização; sobe o serviço
Invoke-RestMethod http://localhost:3008/health                 # "versao" = a anterior
```

> **Cuidado: restaurar o backup apaga tudo o que foi gravado depois dele.** Se algum lote foi transmitido à Receita
> Federal entre a atualização e a restauração, o banco restaurado perde o recibo desse lote. Restaure logo depois da
> atualização, ou confira antes em **Lotes** que nada foi transmitido nesse intervalo.
