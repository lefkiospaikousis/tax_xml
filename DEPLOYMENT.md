# Deploying the DPI XML app to production (Windows + NSSM)

The Shiny app (`app.R`) runs on the production Windows server as a Windows
service managed by [NSSM](https://nssm.cc/). NSSM starts `run_app.R` with
R 4.3.3, keeps it running and restarts it if it crashes. Users open it in
their browser at `http://<server-name>:3845/`.

| | |
|---|---|
| Service name | `DPI_XML_App` |
| Port | `3845` (improreconcile already uses `3844`) |
| Folder on the server | `C:\Users\administrator.ACSCY\Documents\tax_xml` |
| R version | **4.3.3** (must match `renv.lock`) |
| Git branch on GitHub | `master` |
| Log file | `logs\app.log` inside the app folder |

The rest of this guide uses this folder and port. If you choose others,
change them in every command.

---

## 0. Before you go to the server: push

Locally the branch is called `main`, but it tracks `master` on GitHub, so a
plain `git push` will refuse. Push with:

```cmd
git push origin main:master
```

Anything not pushed will not be on the server.

---

## 1. One-time server setup

### 1.1 Install the prerequisites

- **R 4.3.3** at `C:\Program Files\R\R-4.3.3`. Other R versions can stay
  installed side by side, but the service must use 4.3.3.
- **Git for Windows**.
- **NSSM**: already on the server for improreconcile. The commands below
  assume `nssm` is on the PATH; otherwise use its full path, e.g.
  `C:\nssm\win64\nssm.exe`.
- Internet access from the server, so `renv` can download packages.

### 1.2 Clone the project (not into OneDrive)

```cmd
cd C:\Users\administrator.ACSCY\Documents
git clone https://github.com/lefkiospaikousis/tax_xml.git
cd tax_xml
```

> **Do not run the service from a OneDrive folder.** The service runs as
> *LocalSystem*, which can't download OneDrive "Files On-Demand" files that
> are only in the cloud. OneDrive can also sync changes into the folder while
> the app is running.

### 1.3 Install the R packages (renv)

Run this **from inside the project folder**, because the project's
`.Rprofile` activates renv:

```cmd
cd C:\Users\administrator.ACSCY\Documents\tax_xml
set RENV_CONFIG_CACHE_ENABLED=FALSE
"C:\Program Files\R\R-4.3.3\bin\Rscript.exe" -e "renv::restore(prompt = FALSE)"
```

`RENV_CONFIG_CACHE_ENABLED=FALSE` installs the packages *into the project
folder* (`renv\library\R-4.3\...`). Without it, renv links them to a cache in
your own user profile. The service doesn't run as you, and it should not
depend on your profile.

Restore installs the exact package versions in `renv.lock`. If a package
fails because it needs compiling, install
[Rtools43](https://cran.r-project.org/bin/windows/Rtools/rtools43/rtools.html)
and run the command again.

### 1.4 Smoke test by hand

```cmd
"C:\Program Files\R\R-4.3.3\bin\Rscript.exe" C:\Users\administrator.ACSCY\Documents\tax_xml\run_app.R
```

The console prints the URLs, e.g. `App URL(s): http://SERVERNAME:3845/
http://10.x.x.x:3845/`. Open one in a browser on the server, upload a
producers file, press **Generate DPI XML**, and check that it says **XSD
validation: PASSED**. Stop it with **Ctrl+C**.

### 1.5 Install the NSSM service

Open a command prompt **as Administrator**:

```cmd
set APPDIR=C:\Users\administrator.ACSCY\Documents\tax_xml

nssm install DPI_XML_App "C:\Program Files\R\R-4.3.3\bin\Rscript.exe" "%APPDIR%\run_app.R"
nssm set DPI_XML_App AppDirectory "%APPDIR%"
nssm set DPI_XML_App AppEnvironmentExtra APP_PORT=3845
nssm set DPI_XML_App DisplayName "DPI XML Generator (Shiny)"
nssm set DPI_XML_App Start SERVICE_AUTO_START
nssm set DPI_XML_App AppExit Default Restart
nssm set DPI_XML_App AppRestartDelay 10000
nssm set DPI_XML_App AppStdout "%APPDIR%\logs\service.log"
nssm set DPI_XML_App AppStderr "%APPDIR%\logs\service.log"

nssm start DPI_XML_App
```

What each part does:

- **Application = `Rscript.exe`, argument = `run_app.R`.** Point NSSM
  straight at `Rscript.exe`, **not at a `.bat` file**. With a `.bat`,
  stopping the service stops `cmd.exe` but can leave the `Rscript` process
  running and holding port 3845, so the next start fails with "Failed to
  create server".
- **`AppDirectory`** = the project folder, so R starts there and `.Rprofile`
  activates renv. `run_app.R` also activates renv itself as a safety net.
- **`APP_PORT`** sets the port. You can also pass it as a second argument
  instead: `... run_app.R 3845`.
- **`AppExit Default Restart`** + **`AppRestartDelay`**: if the app crashes,
  NSSM restarts it after 10 s. `run_app.R` exits with code 1 on errors so
  NSSM can tell.
- **`AppStdout` / `AppStderr`** catch anything printed *before* `run_app.R`
  starts its own log, e.g. "Rscript.exe not found". Normal logging goes to
  `logs\app.log`.

Instead of the commands, you can use the GUI: `nssm edit DPI_XML_App`.

### 1.6 Open the firewall port (once)

```cmd
netsh advfirewall firewall add rule name="DPI XML app (Shiny 3845)" dir=in action=allow protocol=TCP localport=3845 profile=domain,private
```

`profile=domain,private` keeps it off public networks. See *Security* below.

### 1.7 Check it from another PC

Open `http://<server-name>:3845/`. If the name doesn't resolve, use the IP
shown in `logs\app.log`.

---

## 2. Every update (pull to production)

```cmd
cd C:\Users\administrator.ACSCY\Documents\tax_xml
nssm stop DPI_XML_App

git pull

set RENV_CONFIG_CACHE_ENABLED=FALSE
"C:\Program Files\R\R-4.3.3\bin\Rscript.exe" -e "renv::restore(prompt = FALSE)"

nssm start DPI_XML_App
```

- `renv::restore()` takes a few seconds and changes nothing if `renv.lock`
  didn't change, so it's safe to run every time.
- Then open the app, generate once with a real file, and check **XSD
  validation: PASSED**.
- Check the end of `logs\app.log` for an `ERROR:` line.

### Rolling back

```cmd
nssm stop DPI_XML_App
git log --oneline -10            REM find the last good commit
git checkout <commit-id>
"C:\Program Files\R\R-4.3.3\bin\Rscript.exe" -e "renv::restore(prompt = FALSE)"
nssm start DPI_XML_App
```

Go back to normal with `git checkout master` followed by the update steps.

> **Never edit files directly on the server.** `git pull` will then refuse
> or conflict. Change things locally, commit, push, pull.

---

## 3. Configuration: no golem-config here

improreconcile is a **golem** package. Its `inst/golem-config.yml` switches
database paths, report folders and so on by profile (`default`,
`production`, `acs`), and its `app.R` selects one with
`GOLEM_CONFIG_ACTIVE=production`.

**This app is not a golem app and has no `golem-config.yml`.** It has nothing
that differs between your PC and the server:

- no database, and no output or report folders. The XML is built in memory
  and goes to the browser's download.
- the input Excel file is uploaded through the browser, not read from disk.
  `data\DAC FINAL 2025.xlsx` is git-ignored on purpose and isn't needed on
  the server.
- the XSD schemas it validates against (`data\xsd_validation\`) are in git.

So the only per-machine settings are:

| Setting | Where | Default |
|---|---|---|
| Port | `APP_PORT` in NSSM, or the argument after `run_app.R` | `3845` |
| R version | the `Rscript.exe` path in the NSSM *Application* field | R 4.3.3 |

### Values that are in the code (change by commit, not on the server)

`DEFAULTS` at the top of `app.R` pre-fills the form:

- platform operator TIN, VAT, legal name, business name, street, postcode, city
- reporting year (**currently `2025`**)
- message type (`DPI401`)
- placeholder date of birth (`1900-01-01`)

Users can change any of these on screen for a run. To change a **default**,
edit `app.R` locally, commit, push and pull. Each year, bump the default
reporting year.

> The operator values were first entered as sample data (see `CLAUDE.md`).
> **Verify the TIN, VAT and address against the real operator details
> before the first real submission.**

`xml.R` (the command-line script) still contains a hardcoded
`path_main <- "c:/Users/pcuser/..."`. That only affects running `xml.R` by
hand. The app does not use it.

---

## 4. Things to be aware of

- **R version.** On the development PC, the `Rscript` on the PATH is
  **R 4.1.0**, not 4.3.3, and the old improreconcile `.bat` also calls
  4.1.0. Always use the full path to 4.3.3. `logs\app.log` shows which R
  ran and warns if it doesn't match `renv.lock`.
- **One R process serves everyone.** While one person's XML is generating
  (about 5 s for ~110 sellers), other users' screens wait. This is fine for
  a few users.
- **Upload size limit.** Shiny refuses uploads over **5 MB** by default.
  The producers file is ~40 KB. If it ever gets bigger, add
  `options(shiny.maxRequestSize = 30 * 1024^2)` at the top of `app.R`.
- **Security.** The app has **no login and runs over plain HTTP**, yet the
  data includes sellers' names, TINs, dates of birth and IBANs. Keep it on
  the internal network only: don't forward port 3845 on the router or
  expose it to the internet.
- **Producers files must never be committed.** `data\.gitignore` only
  excludes `DAC FINAL 2025.xlsx` by exact name. Next year's file would show
  up as committable. Consider changing that line to `*.xlsx`.
- **Logs grow.** `logs\app.log` is appended to on every start and is never
  trimmed. Delete it now and then while the service is stopped. The
  `logs\` folder is git-ignored.
- **Stopping the service** kills R directly, so a normal stop may not write
  the `app stopped` line. That is expected. Only an `ERROR:` line means
  something went wrong.

---

## 5. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| Service starts, then stops/restarts repeatedly | the app crashes at startup | read the last lines of `logs\app.log` (and `logs\service.log`) for `ERROR:` |
| `ERROR: Failed to create server` | port 3845 already in use, often an orphaned `Rscript` | `netstat -ano \| findstr :3845` → note the PID → `taskkill /PID <pid> /F` → `nssm start DPI_XML_App` |
| `there is no package called '...'` | renv packages not installed for R 4.3 | run the `renv::restore()` command from 1.3 |
| Log warns R version doesn't match `renv.lock` | NSSM points at a different R | `nssm edit DPI_XML_App` → *Application* → R 4.3.3's `Rscript.exe` |
| Works on the server, not from other PCs | firewall | check the rule from 1.6; try the IP instead of the name |
| `XSD validation: FAILED` | data problem in the uploaded file, or schema files missing | the Results section lists the errors; check `data\xsd_validation\` exists |
| `git pull` refuses: "local changes would be overwritten" | someone edited files on the server | `git status` to see what; `git checkout -- <file>` to discard |

Useful service commands:

```cmd
nssm status  DPI_XML_App
nssm restart DPI_XML_App
nssm edit    DPI_XML_App      REM GUI with all settings
nssm remove  DPI_XML_App confirm
```
