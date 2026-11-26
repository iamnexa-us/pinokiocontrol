#!/bin/bash
# install.sh — Instalação/atualização idempotente do Pinokio (fonte 100% oficial)
#              + VALIDAÇÃO DE SAÚDE (self-heal) + PERSISTÊNCIA/AUTOSTART
#              + GATE DE COMPATIBILIDADE GLIBC + pinokiocontrol.
#
# Uso em uma linha:
#   curl -fsSL https://raw.githubusercontent.com/iamnexa-us/pinokiocontrol/main/install.sh | sudo bash
#
# Ou local:
#   sudo bash install.sh
#
# O QUE FAZ (v.261121a; itens 3 e 10 revistos na v.261126a):
#   1. Descobre a versão LATEST oficial no GitHub (pinokiocomputer/pinokio).
#   2. Baixa o .deb OFICIAL da arquitetura da máquina (amd64 ou arm64).
#   3. GATE GLIBC (novo; lição do 2026-11-21): o 8.4.0 upstream compilou o
#      pty.node contra GLIBC 2.42 — Debian 13 tem 2.41 — e o app MORRIA no
#      main process (sem UI, sem porta 42000, sem SearXNG). Antes de instalar
#      QUALQUER versão, o .deb é aberto (dpkg-deb -x) e o pty.node é
#      inspecionado (objdump): exige GLIBC > host => candidato REJEITADO.
#      Fallback automático para o último KNOWN_GOOD (default 8.3.7); o
#      veredito do gate é cacheado por (versão, glibc do host) para não
#      baixar 128MB de novo a cada rerun idempotente — e, desde a v.261126a,
#      junto com a IDENTIDADE do asset avaliado (sha256): o upstream
#      substituiu o .deb da 8.4.1 NO LUGAR (mesma tag) em 2026-11-25 e o
#      veredito do build quebrado, cacheado só por versão, bloqueou a
#      correção. Hoje um "incompatível" só pula o download se o asset
#      publicado for o MESMO que foi avaliado (ou se o veredito for
#      recente, quando a API não informa o digest).
#   4. AUTO-REPARO: instalação existente com pty.node incompatível (ex.:
#      alguém rodou o .deb na mão / auto-update interno) => DOWNGRADE
#      automático para o melhor candidato compatível. (O "nunca downgrade"
#      das versões anteriores passou a valer só p/ downgrades SEM motivo.)
#   5. AUTO-UPDATER NEUTRALIZADO por padrão (foi ELE quem matou a frota:
#      baixou 8.4.0, rodou dpkg -i e quitAndInstall em cima de um app são).
#      app-update.yml ganha repo inválido (backup .installer-bak preservado)
#      e o cache pending do updater é limpo. Updates passam a ser gestão do
#      instalador/pinokiocontrol --update. PINOKIO_ALLOW_AUTOUPDATE=1 restaura
#      o comportamento nativo (e o backup do yml).
#   6. Instala o pinokiocontrol (--status/--update/--start/--stop/--restart/
#      --persistent ON|OFF) em /opt/pinokiocontrol/bin + symlink
#      /usr/local/bin/pinokiocontrol.
#   7. Compat vnccontrol v261121+ (layout FHS): session-apps em
#      /var/lib/vnccontrol/vnc.session-apps quando o novo STATE_DIR existir;
#      máquinas legadas continuam em /dev-work/.env.
#   8. Verifica o sha256 do asset (publicado pelo upstream) antes de instalar.
#   9. AUTO-VERIFICAÇÃO final com veredito claro (rc=0 OK / rc=1 RESSALVAS).
#      Instância única garantida por flock (sem instalações concorrentes).
#  10. REINÍCIO após troca de arquivos (v.261126a): UPGRADE/REPAIR/REINSTALL
#      com o app em execução => "pinokiocontrol --restart" no fim — cerca de
#      1 min sem a UI :42000 e sem o SearXNG :8888. Antes o processo antigo
#      seguia rodando o build antigo (pelos inodes antigos) até alguém
#      reiniciar, com o veredito dizendo "UPGRADE concluído".
#      "Em execução" = processo cujo EXECUTÁVEL está em /opt/Pinokio (não por
#      substring na linha de comando). O app relança num scope próprio da
#      system.slice: nunca no cgroup de quem chamou (v.261126b).
#      PINOKIO_SKIP_AUTOSTART=1 pula o reinício — o build antigo segue no ar
#      até um "pinokiocontrol --restart" (o instalador avisa).
#  11. Instalação SÃ nunca é rebaixada (v.261126b): com a latest recusada
#      pelo gate, um candidato mais antigo que a versão instalada e saudável
#      é ignorado (antes: "UPGRADE" que era um downgrade silencioso). Pin
#      explícito (PINOKIO_INSTALLER_VERSION) continua podendo rebaixar.
#
# NOTA DE REDE (host-arsenal): SearXNG é SEMPRE acessado em :8888 (Home
# Server do Pinokio). O instalador NUNCA reconfigura portas — só verifica.
#
# Variáveis opcionais (úteis para testes/sandbox):
#   PINOKIO_INSTALLER_ROOT          prefixo de realocação de TODAS as rotas de
#                                   sistema ("" = máquina real; p/ sandbox)
#   PINOKIO_INSTALLER_REPO         repo upstream (default pinokiocomputer/pinokio)
#   PINOKIO_INSTALLER_STATE_DIR    estado do instalador (default /var/lib/pinokio-installer)
#   PINOKIO_INSTALLER_DL_DIR       dir de download (default: temporário automático)
#   PINOKIO_INSTALLER_VERSION      instala EXATAMENTE esta versão (aborta se
#                                  incompatível com o host — sem fallback)
#   PINOKIO_INSTALLER_KNOWN_GOODS  fallbacks após a latest (default "8.3.7")
#   PINOKIO_ALLOW_AUTOUPDATE=1     mantém o auto-updater nativo do app
#   PINOKIO_SKIP_AUTOSTART=1       não integrar/subir via vnccontrol (só instala)
#   PINOKIOCONTROL_BIN_DIR         destino do pinokiocontrol (default /opt/pinokiocontrol/bin)
#   PINOKIOCONTROL_LINK_DIR        dir do symlink (default /usr/local/bin)
#   VNCCONTROL_STATE_DIR           STATE_DIR do vnccontrol (detecta sozinho se vazio)
#   PINOKIO_GATE_CACHE_TTL         prazo (s) de um veredito "incompatível" em
#                                  cache QUANDO a API não informa o digest do
#                                  asset (default 86400 = 24h)
#   PINOKIO_SEARX_WAIT             segundos de espera pelo SearXNG :8888 após
#                                  um reinício (default 90)
#   GITHUB_TOKEN                   opcional, alivia rate limit da API do GitHub

set -euo pipefail

SCRIPT_VERSION="261126b-pub1"
APP="pinokio"
PKG="pinokio"
UP_REPO="${PINOKIO_INSTALLER_REPO:-pinokiocomputer/pinokio}"
STATE_DIR="${PINOKIO_INSTALLER_STATE_DIR:-/var/lib/pinokio-installer}"
DL_DIR="${PINOKIO_INSTALLER_DL_DIR:-}"
# Prefixo de realocação p/ sandbox/testes ("" = máquina real). Toda rota de
# sistema abaixo é relativa a ele — o instalador inteiro fica relocável.
SYS_ROOT="${PINOKIO_INSTALLER_ROOT:-}"
DESKTOP_FILE="$SYS_ROOT/usr/share/applications/pinokio.desktop"
LAUNCHER="$SYS_ROOT/usr/bin/pinokio"
APP_BIN="$SYS_ROOT/opt/Pinokio/pinokio"
SANDBOX_BIN="$SYS_ROOT/opt/Pinokio/chrome-sandbox"
ICON_NAME="pinokio"
MIN_SIZE_BYTES=50000000   # sanidade: .deb do Pinokio tem ~120 MB
STATE_FILE="$STATE_DIR/state"
HISTORY_FILE="$STATE_DIR/history.log"
LOCK_FILE="$STATE_DIR/lock"
GATE_CACHE="$STATE_DIR/glibc-gate.cache"
# v.261126a: prazo (segundos) de confiança de um veredito "incompatível" em
# cache QUANDO não há como conferir a identidade do asset (API do GitHub fora
# ou sem digest). Com a identidade conferível (sha256 da API) o prazo não
# entra em jogo: asset diferente => reavalia, seja qual for a idade.
GATE_CACHE_TTL="${PINOKIO_GATE_CACHE_TTL:-86400}"
case "$GATE_CACHE_TTL" in ''|*[!0-9]*) GATE_CACHE_TTL=86400 ;; esac
# v.261126b: quanto esperar o SearXNG (:8888) depois de um reinício, em
# segundos (cada tentativa de leitura ainda tem 5 s de timeout próprio).
SEARX_WAIT="${PINOKIO_SEARX_WAIT:-90}"
case "$SEARX_WAIT" in ''|*[!0-9]*) SEARX_WAIT=90 ;; esac
APP_DIR="$SYS_ROOT/opt/Pinokio"          # (= dirname de APP_BIN) dir do app

# --- pinokiocontrol --------------------------------------------------------
PC_BIN_DIR="${PINOKIOCONTROL_BIN_DIR:-$SYS_ROOT/opt/pinokiocontrol/bin}"
PC_LINK_DIR="${PINOKIOCONTROL_LINK_DIR:-$SYS_ROOT/usr/local/bin}"
PC_LINK="$PC_LINK_DIR/pinokiocontrol"

# --- Persistência / autostart (padrão do lab: área VNC via vnccontrol) ------
SESSION_APP_ID="pinokio"                     # id usado pelo vnccontrol
VNC_DISPLAY=":99"                            # X_DISPLAY do vnccontrol
SKIP_AUTOSTART="${PINOKIO_SKIP_AUTOSTART:-0}"
# v261121a: vnccontrol >= v261121 (FHS) guarda session-apps no STATE_DIR novo.
vc_session_apps_file() {
    local d="${VNCCONTROL_STATE_DIR:-}"
    [ -z "$d" ] && [ -d "$SYS_ROOT/var/lib/vnccontrol" ] && d="$SYS_ROOT/var/lib/vnccontrol"
    [ -n "$d" ] && [ -d "$d" ] && { printf '%s/vnc.session-apps' "$d"; return 0; }
    # v.261121e (R3): branch legada TAMBÉM sob $SYS_ROOT — sem o argumento, um
    # "teste sandbox" escrevia na lista REAL /dev-work de produção.
    printf '%s/dev-work/.env/vnc.session-apps' "$SYS_ROOT"
}
SESSION_APPS_FILE="$(vc_session_apps_file)"

# Caminho do pty.node dentro do /opt do app e dentro do .deb (igual nas
# versões 8.x conhecidas — validado contra 8.3.7 e 8.4.0 reais).
PTY_REL="resources/app.asar.unpacked/node_modules/@homebridge/node-pty-prebuilt-multiarch/build/Release/pty.node"

KNOWN_GOODS="${PINOKIO_INSTALLER_KNOWN_GOODS:-8.3.7}"

# Linhas OBRIGATÓRIAS do desktop entry (mesmo conteúdo do .deb oficial).
DESKTOP_REQUIRED_LINES=(
    "[Desktop Entry]"
    "Name=Pinokio"
    "Exec=/opt/Pinokio/pinokio %U"
    "Terminal=false"
    "Type=Application"
    "Icon=pinokio"
    "StartupWMClass=Pinokio"
)

LATEST_TAG=""; ASSET_NAME=""; ASSET_URL=""; ASSET_SIZE=""; ASSET_SHA=""
WARN_ITEMS=""; HEALED_ITEMS=""; PERSIST_STATUS="nao-aplicavel"
DL_DIR_CREATED=0
ACTION=""

info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[AVISO] $*"; WARN_ITEMS="${WARN_ITEMS:+$WARN_ITEMS; }$*"; }
healed(){ echo "[HEAL]  $*"; HEALED_ITEMS="${HEALED_ITEMS:+$HEALED_ITEMS; }$*"; }
skip()  { echo "[SKIP]  $*"; }
die()   { echo "[ERRO]  $*" >&2; exit 1; }

cleanup() {
    if [ "$DL_DIR_CREATED" = "1" ] && [ -n "$DL_DIR" ] && [ -d "$DL_DIR" ]; then
        rm -rf "$DL_DIR"
    fi
}
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || die "Execute como root (ex.: ... | sudo bash)."
: "${HOME:=/root}"
export DEBIAN_FRONTEND=noninteractive

command -v curl >/dev/null 2>&1 || die "curl não encontrado. Instale com: apt-get install -y curl"
command -v apt-get >/dev/null 2>&1 || die "apt-get não encontrado: este instalador exige Debian/Ubuntu (dpkg)."
command -v dpkg >/dev/null 2>&1 || die "dpkg não encontrado: este instalador exige Debian/Ubuntu."
command -v flock >/dev/null 2>&1 || die "flock não encontrado. Instale com: apt-get install -y util-linux"
# v.261121d (R1): sem objdump o gate GLIBC fica CEGO e aprovava binários
# quebrados com veredito rc=0 — binutils é dependência OBRIGATÓRIA.
command -v objdump >/dev/null 2>&1 || die "objdump não encontrado (binutils) — o gate GLIBC é obrigatório. Instale com: apt-get install -y binutils"

# ---------------------------------------------------------------------------
# Instância única: duas execuções concorrentes (ex.: apt + cron + humano)
# corromperiam estado/download. Lock exclusivo no STATE_DIR.
# ---------------------------------------------------------------------------
mkdir -p "$STATE_DIR" 2>/dev/null || die "não foi possível criar o STATE_DIR ($STATE_DIR) — disco cheio? permissão?"
exec 9>"$LOCK_FILE" || die "não foi possível abrir o lock ($LOCK_FILE)"
flock -n 9 || die "Outra execução do instalador está em andamento (lock: $LOCK_FILE)."

# v.261121d: quando invocado via "pinokiocontrol --update" (exec com o fd 8
# do lock do CLI aberto), fechar ANTES de qualquer spawn — filhos de longa
# vida (rings do vnccontrol, o próprio pinokio) herdariam esse fd e
# travariam o pinokiocontrol até o reboot (lockout — achado R2, round 1).
# v.261121e (R1/R2 r2): o redirect NO EXEC é PERMANENTE — "exec 8>&-
# 2>/dev/null" matava o stderr do instalador inteiro (todo die mudo).
# Redirect no BLOCO: fecha o fd sem tocar o stderr do script.
{ exec 8>&-; } 2>/dev/null || true

# O hold do apt NÃO protege contra o auto-updater (ele usa dpkg -i, que
# ignora hold) e só atrapalha o apt com .deb local — o instalador é o dono
# do estado do pacote: remove hold residual de intervenções manuais.
apt-mark unhold "$PKG" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Arquitetura → sufixo do asset oficial
# ---------------------------------------------------------------------------
case "$(uname -m)" in
    x86_64)         DEB_ARCH="amd64" ;;
    aarch64|arm64)  DEB_ARCH="arm64" ;;
    *) die "Arquitetura não suportada: $(uname -m) (use amd64 ou arm64)." ;;
esac
ASSET_RE="Pinokio_[0-9][0-9A-Za-z.]*_${DEB_ARCH}\\.deb"

# Permissão alvo do chrome-sandbox — MESMA regra do postinst oficial do
# Pinokio: 0755 quando o kernel suporta user namespaces, 4755 caso contrário.
if { [ -L /proc/self/ns/user ] && unshare --user true; } 2>/dev/null; then
    SANDBOX_WANT_PERM="755"
else
    SANDBOX_WANT_PERM="4755"
fi

# Nome canônico do asset para uma tag (sem o 'v' inicial).
asset_for_tag() {  # $1 = versão sem 'v'
    printf 'Pinokio_%s_%s.deb' "$1" "$DEB_ARCH"
}

echo "=============================================================="
echo " Instalador do Pinokio (fonte oficial: github.com/$UP_REPO)"
echo " Máquina: $(hostname) · $(uname -m) → $DEB_ARCH · $(date '+%d/%m/%Y %H:%M')"
echo "=============================================================="

# ---------------------------------------------------------------------------
# GATE GLIBC — o coração do v.261121a
# ---------------------------------------------------------------------------
# Nota: NUNCA usar "ldd --version | head -1" aqui — o head fecha a pipe antes
# do ldd terminar de escrever suas ~5 linhas; sob pipefail o SIGPIPE (141)
# matava o instalador silenciosamente de forma INTERMITENTE (corrida). O
# sed -n consome todo o input: sem early-exit, sem SIGPIPE, determinístico.
host_glibc() {
    local out=""
    out=$(ldd --version 2>/dev/null | sed -n '1s/.* \([0-9][0-9]*\.[0-9][0-9]*\)$/\1/p')
    printf '%s' "$out"
}

# Maior GLIBC_2.x exigido por um binário .node (vazio = sem objdump/sem req).
# Nota pipefail: objdump em arquivo não-ELF (corrompo/exótico) retorna != 0 e
# grep sem match idem — a atribuição é blindada com || para não matar o
# instalador sob set -euo pipefail (o gate então "sem informação" = permite).
bin_glibc_max() {  # $1 = caminho do arquivo
    local f="$1" out
    [ -f "$f" ] || { echo ""; return 0; }
    command -v objdump >/dev/null 2>&1 || { echo ""; return 0; }
    out=$(objdump -T "$f" 2>/dev/null | grep -oE 'GLIBC_2\.[0-9]+' | sort -uV | tail -1) || out=""
    printf '%s' "${out#GLIBC_}"
}

# need <= have (comparação por sort -V; vazio => ok — sem informação, permite).
glibc_ok() {  # $1 = exigido
    local need="$1" have top
    [ -n "$need" ] || return 0
    have=$(host_glibc)
    [ -n "$have" ] || return 0
    [ "$need" = "$have" ] && return 0
    top=$(printf '%s\n%s\n' "$need" "$have" | sort -V | tail -1)
    [ "$top" = "$have" ]
}

# Maior GLIBC exigido pelo pty.node DENTRO de um .deb (extrai só o arquivo).
# v.261121d (R1): a rota interna do .deb é absoluta-raiz (opt/Pinokio/...) —
# NÃO se concatena $SYS_ROOT na extração (o dpkg-deb real sempre extrai em
# $tmp/opt/...); a concatenação anterior cegava o gate em sandbox.
deb_glibc_max() {  # $1 = .deb
    local deb="$1" tmp out
    tmp=$(mktemp -d 2>/dev/null) || { echo ""; return 0; }
    dpkg-deb -x "$deb" "$tmp" 2>/dev/null || { rm -rf "$tmp"; echo ""; return 0; }
    out=$(bin_glibc_max "$tmp/opt/Pinokio/$PTY_REL")
    rm -rf "$tmp"
    printf '%s' "$out"
}

# Instalação ATUAL é compatível com o host? (pty.node já em /opt)
installed_glibc_ok() {
    local need
    need=$(bin_glibc_max "$SYS_ROOT/opt/Pinokio/$PTY_REL")
    glibc_ok "$need"
}

HOST_GLIBC="$(host_glibc)"
[ -n "$HOST_GLIBC" ] && info "GLIBC do host: $HOST_GLIBC" \
                     || warn "não consegui ler o glibc do host (ldd) — gate GLIBC menos estrito."

# Cache do veredito do gate — uma linha por (versão, glibc do host):
#     versao|glibc -> NEED sha256=<asset AVALIADO> at=<epoch>
# NEED é o maior GLIBC que o pty.node do .deb exige (como sempre). sha256/at
# são a IDENTIDADE do que foi avaliado (v.261126a). Linhas do formato antigo
# (só o NEED) continuam legíveis, mas NUNCA servem para pular um download:
# não há como saber de que asset são — reavalia uma vez e reescreve.
# gate_cache_lookup preenche CACHE_NEED / CACHE_SHA / CACHE_AT.
gate_cache_lookup() {  # $1=versao $2=glibc → 0 = há entrada (1 = não há)
    local line kv ver_re glibc_re
    CACHE_NEED=""; CACHE_SHA=""; CACHE_AT=""
    [ -r "$GATE_CACHE" ] || return 1
    ver_re="${1//./\\.}"; glibc_re="${2//./\\.}"
    line=$(sed -n "s/^$ver_re|$glibc_re -> //p" "$GATE_CACHE" 2>/dev/null | tail -1) || line=""
    [ -n "$line" ] || return 1
    CACHE_NEED="${line%%[[:space:]]*}"
    for kv in ${line#"$CACHE_NEED"}; do
        case "$kv" in
            sha256=*) CACHE_SHA="${kv#sha256=}" ;;
            at=*)     CACHE_AT="${kv#at=}" ;;
        esac
    done
    case "$CACHE_AT" in *[!0-9]*) CACHE_AT="" ;; esac   # corrompida = sem data
    return 0
}

# Data legível da entrada que gate_cache_lookup acabou de ler.
gate_cache_date() {
    [ -n "$CACHE_AT" ] || { printf 'data desconhecida'; return 0; }
    date -d "@$CACHE_AT" '+%d/%m/%Y %H:%M' 2>/dev/null || printf '%s' "$CACHE_AT"
}

# Um veredito "incompatível" em cache pode PULAR o download?
#   • é do MESMO asset publicado agora (sha256 do cache = sha256 da API) → sim;
#   • sem como conferir a identidade (API fora/sem digest) → só dentro do
#     prazo GATE_CACHE_TTL;
#   • entrada sem identidade (formato antigo) → nunca: reavalia uma vez.
gate_cache_trusted() {  # $1=versao $2=glibc $3=sha256 publicado agora (vazio = desconhecido)
    local age
    gate_cache_lookup "$1" "$2" || return 1
    [ -n "$CACHE_AT" ] || return 1
    if [ -n "${3:-}" ] && [ -n "$CACHE_SHA" ] && [ "$CACHE_SHA" != none ]; then
        [ "$3" = "$CACHE_SHA" ]
        return
    fi
    age=$(( $(date +%s) - CACHE_AT ))
    [ "$age" -ge 0 ] && [ "$age" -le "$GATE_CACHE_TTL" ]
}

# Grava/substitui a entrada (versao, glibc) — atômico e best-effort (o cache
# nunca derruba o instalador). $4 = sha256 REAL do asset que foi avaliado.
# Toda avaliação INVALIDA a entrada anterior da chave: veredito "sem
# informação" (gate cego, NEED vazio) remove a linha e não grava outra —
# nunca vira atalho, e um "incompatível" velho não sobrevive a um build bom.
gate_cache_put() {  # $1=versao deb $2=glibc host $3=need $4=sha256 avaliado
    [ -f "$GATE_CACHE" ] || [ -n "$3" ] || return 0
    grep -v "^$1|$2 -> " "$GATE_CACHE" 2>/dev/null > "$GATE_CACHE.tmp" || true
    [ -z "$3" ] || echo "$1|$2 -> $3 sha256=${4:-none} at=$(date +%s)" >> "$GATE_CACHE.tmp" 2>/dev/null || true
    mv -f "$GATE_CACHE.tmp" "$GATE_CACHE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Versão atualmente instalada (vazia se não houver)
# ---------------------------------------------------------------------------
installed_version() {
    local st
    st=$(dpkg-query -W -f='${Status}' "$PKG" 2>/dev/null || true)
    case "$st" in
        *"install ok installed"*) dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null ;;
        *) echo "" ;;
    esac
}

# Saúde de ARQUIVOS (usada pela decisão E pela auditoria final — definida
# cedo porque a decisão de INSTALL/REINSTALL precisa dela antes do install).
app_bin_ok()      { [ -f "$APP_BIN" ] && [ -x "$APP_BIN" ]; }
sandbox_present() { [ -f "$SANDBOX_BIN" ]; }
icons_ok() {
    local f
    for f in "$SYS_ROOT"/usr/share/icons/hicolor/*/apps/"$ICON_NAME".png; do
        [ -f "$f" ] && return 0
    done
    return 1
}
critical_damage() {
    if [ -n "$(installed_version)" ]; then
        app_bin_ok      || return 0
        icons_ok        || return 0
        sandbox_present || return 0
    fi
    return 1
}

# SearXNG na :8888 (informativo — rede padrão; NUNCA reconfiguramos portas).
# O estado ANTES da troca fica lembrado para o veredito saber se ele voltou.
searx_code() {
    local c
    c=$(curl -m 5 -sS -o /dev/null -w '%{http_code}' 'http://127.0.0.1:8888/search?q=x&format=json' 2>/dev/null) || c="000"
    printf '%s' "${c:-000}"
}
SEARX_BEFORE="$(searx_code)"

CURRENT_VER="$(installed_version)"
if [ -n "$CURRENT_VER" ]; then
    info "Pinokio atualmente instalado: $CURRENT_VER"
    if installed_glibc_ok; then
        info "pty.node instalado: compatível com o GLIBC do host (OK)"
        RUNTIME_OK=1
    else
        warn "pty.node instalado EXIGE GLIBC superior ao do host — instalação QUEBRADA em runtime (auto-reparo a seguir)."
        RUNTIME_OK=0
    fi
else
    info "Pinokio não está instalado nesta máquina."
    RUNTIME_OK=0
fi

# ---------------------------------------------------------------------------
# Resolver metadados de uma versão (API; fallback redirect).
# Preenche LATEST_TAG/ASSET_NAME/ASSET_URL/ASSET_SHA/ASSET_SIZE.
# resolve_version <ver-sem-v>   |   resolve_latest
# ---------------------------------------------------------------------------
resolve_version() {  # $1 = versão sem 'v'
    local ver="$1" api hdr=() json joined hit
    api="https://api.github.com/repos/$UP_REPO/releases/tags/v$ver"
    [ -n "${GITHUB_TOKEN:-}" ] && hdr=(-H "Authorization: Bearer $GITHUB_TOKEN")
    json=""
    if json=$(curl -fsSL --connect-timeout 15 --max-time 40 \
            -H 'Accept: application/vnd.github+json' \
            -H 'User-Agent: pinokio-installer/1.0' \
            ${hdr[@]+"${hdr[@]}"} "$api" 2>/dev/null); then
        joined=$(printf '%s' "$json" | tr -d '\n\r')
        LATEST_TAG=$(printf '%s' "$joined" | grep -oE '"tag_name": *"[^"]*"' | head -1 \
            | sed -e 's/.*"tag_name": *"//' -e 's/"$//') || LATEST_TAG=""
        ASSET_URL=$(printf '%s' "$joined" | grep -oE '"browser_download_url": *"[^"]*"' \
            | sed -e 's/.*"browser_download_url": *"//' -e 's/"$//' \
            | grep -E "/${ASSET_RE}\$" | tail -1) || ASSET_URL=""
        if [ -n "$ASSET_URL" ]; then
            ASSET_NAME="${ASSET_URL##*/}"
            hit=$(printf '%s' "$joined" | grep -oE \
                "\"digest\": *\"sha256:[0-9a-f]+\"[^{}]*\"browser_download_url\": *\"$ASSET_URL\"" | head -1) || hit=""
            ASSET_SHA=$(printf '%s' "$hit" | sed -n 's/.*"digest": *"sha256:\([0-9a-f]*\)".*/\1/p') || ASSET_SHA=""
            hit=$(printf '%s' "$joined" | grep -oE \
                "\"size\": *[0-9]+, *\"digest\": *\"sha256:$ASSET_SHA\"" | head -1) || hit=""
            ASSET_SIZE=$(printf '%s' "$hit" | sed -n 's/.*"size\": *\([0-9][0-9]*\).*/\1/p') || ASSET_SIZE=""
            return 0
        fi
    fi
    # fallback: URL deduzida (sem sha)
    LATEST_TAG="v$ver"
    ASSET_NAME="$(asset_for_tag "$ver")"
    ASSET_URL="https://github.com/$UP_REPO/releases/download/v$ver/$ASSET_NAME"
    ASSET_SHA=""; ASSET_SIZE=""
    # v.261126b (R1): distinguir "API fora" de "API respondeu, mas sem .deb
    # para esta arquitetura" — o aviso antigo culpava o rate limit nos dois.
    if [ -n "$json" ]; then
        warn "a API do GitHub não listou o .deb ${DEB_ARCH} de v$ver; usando URL deduzida. sha256 não verificado neste modo."
    else
        warn "API do GitHub indisponível para v$ver (rate limit?); usando URL deduzida. sha256 não verificado neste modo."
    fi
    return 0
}

resolve_latest() {
    local api hdr=() json joined redir
    api="https://api.github.com/repos/$UP_REPO/releases/latest"
    [ -n "${GITHUB_TOKEN:-}" ] && hdr=(-H "Authorization: Bearer $GITHUB_TOKEN")
    json=""
    if json=$(curl -fsSL --connect-timeout 15 --max-time 40 \
            -H 'Accept: application/vnd.github+json' \
            -H 'User-Agent: pinokio-installer/1.0' \
            ${hdr[@]+"${hdr[@]}"} "$api" 2>/dev/null); then
        joined=$(printf '%s' "$json" | tr -d '\n\r')
        LATEST_TAG=$(printf '%s' "$joined" | grep -oE '"tag_name": *"[^"]*"' | head -1 \
            | sed -e 's/.*"tag_name": *"//' -e 's/"$//') || LATEST_TAG=""
        ASSET_URL=$(printf '%s' "$joined" | grep -oE '"browser_download_url": *"[^"]*"' \
            | sed -e 's/.*"browser_download_url": *"//' -e 's/"$//' \
            | grep -E "/${ASSET_RE}\$" | tail -1) || ASSET_URL=""
        if [ -n "$LATEST_TAG" ] && [ -n "$ASSET_URL" ]; then
            ASSET_NAME="${ASSET_URL##*/}"
            local hit
            hit=$(printf '%s' "$joined" | grep -oE \
                "\"digest\": *\"sha256:[0-9a-f]+\"[^{}]*\"browser_download_url\": *\"$ASSET_URL\"" | head -1) || hit=""
            ASSET_SHA=$(printf '%s' "$hit" | sed -n 's/.*"digest": *"sha256:\([0-9a-f]*\)".*/\1/p') || ASSET_SHA=""
            hit=$(printf '%s' "$joined" | grep -oE \
                "\"size\": *[0-9]+, *\"digest\": *\"sha256:$ASSET_SHA\"" | head -1) || hit=""
            ASSET_SIZE=$(printf '%s' "$hit" | sed -n 's/.*"size\": *\([0-9][0-9]*\).*/\1/p') || ASSET_SIZE=""
            return 0
        fi
    fi
    # fallback sem API (rate limit/offline p/ api.github.com)
    redir=$(curl -fsS -o /dev/null -w '%{redirect_url}' --connect-timeout 15 \
        --max-time 30 "https://github.com/$UP_REPO/releases/latest" 2>/dev/null || true)
    LATEST_TAG=$(printf '%s' "$redir" | sed -n 's#.*/tag/\([^?]*\)$#\1#p')
    [ -n "$LATEST_TAG" ] || return 1
    ASSET_NAME="$(asset_for_tag "${LATEST_TAG#v}")"
    ASSET_URL="https://github.com/$UP_REPO/releases/download/$LATEST_TAG/$ASSET_NAME"
    ASSET_SIZE=""; ASSET_SHA=""
    warn "API do GitHub indisponível (rate limit?): usando fallback via redirect. sha256 não verificado neste modo."
    return 0
}

# ---------------------------------------------------------------------------
# Download + integridade + GATE GLIBC de um candidato JÁ RESOLVIDO.
# Retorna: 0 = candidato aprovado ($DEB_FILE pronto p/ instalar);
#          2 = reprovado no gate (cacheado); 1 = erro real (die no chamador).
# ---------------------------------------------------------------------------
fetch_candidate() {
    local REAL_SIZE REAL_SHA EVAL_SHA NEED
    if [ -n "$DL_DIR" ]; then mkdir -p "$DL_DIR"; else DL_DIR="$(mktemp -d)"; DL_DIR_CREATED=1; fi
    DEB_FILE="$DL_DIR/$ASSET_NAME"
    info "Baixando $ASSET_URL ..."
    # --speed-limit/--speed-time: conexao STALLADA (ex.: blackhole de MTU,
    # observado ao vivo em 2026-11-21) aborta em 90s com erro claro em vez de
    # pendurar o one-liner para sempre; --max-time como cinto de segurança.
    # v.261121d (R1): rc 22 = erro HTTP (404 = versão inexistente no GitHub)
    # → pular candidato com aviso honesto; outros rc = rede real → falha.
    local dlrc=0
    curl -fL --retry 3 --connect-timeout 15 \
        --speed-limit 1024 --speed-time 90 --max-time 3600 \
        -sS -o "$DEB_FILE" "$ASSET_URL" || dlrc=$?
    if [ "$dlrc" = 22 ]; then
        warn "HTTP 4xx/5xx para $ASSET_URL (versão inexistente?) — candidato pulado."
        return 3
    fi
    if [ "$dlrc" != 0 ]; then
        warn "download falhou (curl rc=$dlrc) para $ASSET_URL"
        return 1
    fi

    REAL_SIZE=$(stat -c '%s' "$DEB_FILE" 2>/dev/null || echo 0)
    if [ -n "$ASSET_SIZE" ] && [ "$REAL_SIZE" != "$ASSET_SIZE" ]; then
        die "Tamanho divergente do oficial ($REAL_SIZE != $ASSET_SIZE). Download corrompido? Abortando."
    fi
    if [ "$REAL_SIZE" -lt "$MIN_SIZE_BYTES" ]; then
        die "Arquivo pequeno demais ($REAL_SIZE bytes) para ser o .deb do Pinokio. Abortando."
    fi
    # v.261126a: IDENTIDADE do que foi avaliado = sha256 real do arquivo em
    # mãos (mesmo no modo fallback, sem API) — é ele que diz, numa próxima
    # execução, se o asset publicado ainda é o mesmo.
    EVAL_SHA=$(sha256sum "$DEB_FILE" 2>/dev/null | awk '{print $1}') || EVAL_SHA=""
    if [ -n "$ASSET_SHA" ]; then
        REAL_SHA="$EVAL_SHA"
        [ -n "$REAL_SHA" ] || die "não foi possível calcular o sha256 do .deb. Abortando sem instalar."
        [ "$REAL_SHA" = "$ASSET_SHA" ] || die "sha256 NÃO confere ($REAL_SHA). Abortando sem instalar."
        ok "sha256 confere com o publicado pelo upstream."
    fi
    dpkg-deb --info "$DEB_FILE" >/dev/null 2>&1 || die "Arquivo não é um .deb válido. Abortando."

    # v.261121d (R1): integridade não verificada (modo fallback sem API) é
    # REGISTRADA — vira ressalva no veredito (antes: rc=0 "OK" silencioso).
    if [ -z "$ASSET_SHA" ]; then
        SHA_UNVERIFIED=1
    else
        SHA_UNVERIFIED=0
    fi

    # ---- gate GLIBC (com cache) ----
    NEED=$(deb_glibc_max "$DEB_FILE")
    gate_cache_put "${LATEST_TAG#v}" "$HOST_GLIBC" "$NEED" "$EVAL_SHA"
    if [ -n "$NEED" ] && ! glibc_ok "$NEED"; then
        warn "Candidato ${LATEST_TAG#v} exige GLIBC $NEED > host $HOST_GLIBC — REJEITADO pelo gate."
        rm -f "$DEB_FILE"
        return 2
    fi
    if [ -n "$NEED" ]; then
        ok "gate GLIBC: ${LATEST_TAG#v} exige no máx $NEED ≤ $HOST_GLIBC — aprovado."
    else
        info "gate GLIBC: sem informação de versão exigida (objdump ausente?) — candidato aprovado sem gate."
    fi
    return 0
}

install_deb() {  # $1 = versão do .deb (p/ log) — usa $DEB_FILE
    local ver="$1"
    info "Instalando $DEB_FILE via apt/dpkg..."
    # hold não protege contra dpkg -i (é o que o updater usava) — só atrapalha
    # o apt com .deb local; removemos se existir.
    apt-mark unhold "$PKG" >/dev/null 2>&1 || true
    local -a apt_cmd=(apt-get install -y)
    # downgrade deliberado (reparo/pin) precisa de flag explícita
    if [ -n "$(installed_version)" ] && dpkg --compare-versions "$ver" lt "$(installed_version)" 2>/dev/null; then
        apt_cmd+=(--allow-downgrades)
    fi
    # repor arquivos da MESMA versão exige --reinstall (apt "already newest" senão)
    [ "${ACTION:-}" = "REINSTALL" ] && apt_cmd+=(--reinstall)
    apt_cmd+=(-- "$DEB_FILE")
    # v.261121d (R3): log sob o STATE_DIR (sandbox-friendly; o /tmp fixo
    # colidia entre execuções e vazava do sandbox)
    local aptlog="$STATE_DIR/apt-install.log"
    if ! "${apt_cmd[@]}" >"$aptlog" 2>&1; then
        warn "apt-get install falhou; tentando dpkg -i + apt-get -f install..."
        dpkg -i -- "$DEB_FILE" >>"$aptlog" 2>&1 \
            || apt-get -f install -y >>"$aptlog" 2>&1 \
            || die "Instalação falhou (log: $aptlog)."
    fi
    rm -f "$DEB_FILE"
}

write_state() {  # $1=modo (install/upgrade/reinstall/adopted/repair/pinned)
    # v.261121d (R3): escrita ATÔMICA e degradação gracosa — ENOSPC/RO vira
    # aviso (e ressalva no veredito), não morte abrupta sem veredito.
    local mode="$1" tmpf="$STATE_FILE.tmp"
    # v.261121e (R1): comparar com CURRENT_VER (a versão ANTES da instalação)
    # — installed_version() já reflete a nova após install_deb e o sufixo
    # -downgrade nunca disparava.
    if [ -n "$CURRENT_VER" ] && dpkg --compare-versions "$CAND_VER" lt "$CURRENT_VER" 2>/dev/null; then
        mode="$mode-downgrade"
    fi
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    if cat > "$tmpf" 2>/dev/null <<EOF
APP=$APP
TAG=$LATEST_TAG
VERSION=${LATEST_TAG#v}
ASSET=$ASSET_NAME
SHA256=${ASSET_SHA:-unknown}
MODE=$mode
HOST_GLIBC=$HOST_GLIBC
INSTALLED_AT=$(date '+%Y-%m-%dT%H:%M:%S%z')
EOF
    then
        chmod 644 "$tmpf" 2>/dev/null || true
        mv -f "$tmpf" "$STATE_FILE" 2>/dev/null \
            || warn "não foi possível gravar o state ($STATE_FILE) — disco/permissão?"
    else
        warn "não foi possível gravar o state ($STATE_FILE) — disco cheio? Somente leitura?"
    fi
    printf '%s | %s | %s -> %s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$mode" \
        "${CURRENT_VER:-nenhuma}" "${LATEST_TAG#v}" "$ASSET_NAME" >> "$HISTORY_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Candidatos: [PINOKIO_INSTALLER_VERSION | latest] + KNOWN_GOODS (dedup).
# Seleciona o PRIMEIRO compatível. Se o candidato == instalado e o instalado
# já é compatível => escolhido SEM download (idempotência barata).
# ---------------------------------------------------------------------------
CAND_VER=""; DEB_FILE=""; SHA_UNVERIFIED=0
select_candidate() {
    local c rc hint_incompat=0
    for c in $CANDIDATES; do
        [ -z "$c" ] && continue
        # candidato == instalado e instalado são => nada a baixar
        if [ "$c" = "$CURRENT_VER" ] && [ "$RUNTIME_OK" = 1 ]; then
            CAND_VER="$c"; ACTION="SKIP"
            # v.261121e (R3): atalho idempotente não baixou NADA — não há sha
            # pendente; sem isso um fetch rejeitado anterior deixava ressalva
            # FALSA de "sha não verificado" em máquina saudável.
            SHA_UNVERIFIED=0
            return 0
        fi
        # v.261126b: instalação SÃ mais nova que o candidato FICA. Antes, com
        # a latest recusada pelo gate, o laço caía no known-good e fazia
        # "UPGRADE" de uma versão sã mais nova — um DOWNGRADE silencioso
        # (ex.: 8.4.1 -> 8.3.7) em todo rerun do one-liner. Pin explícito
        # (PINOKIO_INSTALLER_VERSION) continua podendo rebaixar: é o rollback.
        if [ -z "${PINOKIO_INSTALLER_VERSION:-}" ] && [ "$RUNTIME_OK" = 1 ] && [ -n "$CURRENT_VER" ] \
           && dpkg --compare-versions "$c" le "$CURRENT_VER" 2>/dev/null; then
            skip "Candidato $c não é mais novo que a instalação sã ($CURRENT_VER) — mantida a instalada."
            continue
        fi
        # v.261126a: resolve PRIMEIRO — o sha256 que o GitHub publica é a
        # identidade do asset de HOJE. Só depois consulta o cache: um
        # "incompatível" só pula o download se for veredito DESSE asset (ou
        # se for recente, quando a API não deu identidade). Antes o cache era
        # consultado antes da resolução e valia para sempre.
        if ! resolve_version "$c"; then
            warn "Candidato $c: não resolvido no GitHub — pulando."
            continue
        fi
        hint_incompat=0
        if gate_cache_lookup "$c" "$HOST_GLIBC" && [ -n "$CACHE_NEED" ] && ! glibc_ok "$CACHE_NEED"; then
            hint_incompat=1
            if gate_cache_trusted "$c" "$HOST_GLIBC" "${ASSET_SHA:-}"; then
                skip "Candidato $c: já recusado pelo gate (exige GLIBC $CACHE_NEED > $HOST_GLIBC; asset ${CACHE_SHA:0:12}, avaliado em $(gate_cache_date)) — pulando download."
                continue
            fi
            info "Candidato $c: o cache do gate (exige GLIBC $CACHE_NEED) não identifica o asset publicado hoje — reavaliando."
        fi
        rc=0; fetch_candidate || rc=$?
        if [ "$rc" = 0 ]; then
            CAND_VER="$c"
            return 0
        elif [ "$rc" = 2 ] || [ "$rc" = 3 ]; then
            continue   # gate reprovou (2) ou versão inexistente (3) — próximo
        elif [ "$hint_incompat" = 1 ]; then
            # v.261126b (R2): o cache já dizia "incompatível" (mesmo sem
            # identidade) e a rede falhou nesta reavaliação — não derrubar
            # uma máquina sã SEM veredito (ela perdia a auditoria e a
            # neutralização do updater). Fica o veredito antigo por ora; a
            # próxima execução com rede reavalia do mesmo jeito.
            warn "Candidato $c: o cache diz incompatível (GLIBC $CACHE_NEED) e a reavaliação falhou agora (download rc=$rc) — mantido o veredito antigo; próxima execução com rede reavalia."
            continue
        else
            die "Falha real ao obter o candidato $c (fetch rc=$rc, rede?). Abortando."
        fi
    done
    return 1
}

if [ -n "${PINOKIO_INSTALLER_VERSION:-}" ]; then
    CANDIDATES="${PINOKIO_INSTALLER_VERSION}"
    LATEST_VER="${PINOKIO_INSTALLER_VERSION}"
    info "Versão PINADA via PINOKIO_INSTALLER_VERSION=$PINOKIO_INSTALLER_VERSION (sem fallback; latest = o próprio pin)."
else
    info "Consultando a última release oficial no GitHub..."
    resolve_latest || die "Não foi possível descobrir a última release de github.com/$UP_REPO (rede?). Tente novamente mais tarde."
    LATEST_VER="${LATEST_TAG#v}"
    info "Latest oficial: $LATEST_TAG"
    CANDIDATES="$LATEST_VER $KNOWN_GOODS"
fi
# dedup preservando ordem
CANDIDATES=$(printf '%s\n' $CANDIDATES | awk '!seen[$0]++' | tr '\n' ' ')

DOWNGRADE_NOTE=""
if ! select_candidate; then
    if [ -n "${PINOKIO_INSTALLER_VERSION:-}" ]; then
        die "A versão pinada $PINOKIO_INSTALLER_VERSION não pôde ser instalada (gate GLIBC ou rede)."
    fi
    # v.261121d (R1): instalação SAUDÁVEL já presente é candidata legítima.
    # Antes: die ANTES de neutralizar o updater/auditar — a máquina funcional
    # reportava FALHA e ficava DESPROTEGIDA contra o auto-updater.
    if [ -n "$CURRENT_VER" ] && [ "$RUNTIME_OK" = 1 ] && ! critical_damage; then
        CAND_VER="$CURRENT_VER"; ACTION="PINNED"; DEB_FILE=""
        LATEST_TAG="v$CAND_VER"
        ASSET_NAME="$(asset_for_tag "$CAND_VER")"
        DOWNGRADE_NOTE="nenhum candidato remoto compatível ($CANDIDATES) — instalação atual saudável adotada e protegida"
        # v.261126b: NADA foi instalado nesta execução — o "sha não verificado"
        # de um candidato que foi RECUSADO não é ressalva da instalação em pé
        # (o atalho do candidato instalado-são já fazia o mesmo; aqui não).
        SHA_UNVERIFIED=0
        warn "$DOWNGRADE_NOTE"
    else
        die "Nenhum candidato compatível ($CANDIDATES) e instalação atual ausente/quebrada. Nada feito."
    fi
fi

# ---------------------------------------------------------------------------
# Decisão idempotente: INSTALL / UPGRADE / SKIP / REINSTALL / REPAIR / PINNED
# (DOWNGRADE_NOTE inicializado antes do select_candidate — o caminho "adotar
# instalação saudável isolada" também o preenche)
# ---------------------------------------------------------------------------
if [ -z "$CURRENT_VER" ]; then
    ACTION="${ACTION:-INSTALL}"
elif [ "$CAND_VER" = "$CURRENT_VER" ]; then
    if [ "$RUNTIME_OK" = 0 ]; then
        # v.261121d (R1): o select PODE devolver candidato == instalado com
        # runtime quebrado (o .deb upstream passou no gate — os arquivos
        # LOCAIS é que estão danificados/adulterados). Repor conserta; antes
        # este caminho era um loop infinito rc=1 com promessa falsa de
        # "rode de novo p/ REPAIR".
        ACTION="REINSTALL"
        DOWNGRADE_NOTE="reinstall da mesma versão: pty.node local incompatível/quebrado ($CURRENT_VER)"
        warn "Instalação ($CURRENT_VER) com pty.node quebrado → REINSTALL da mesma versão (deb aprovado em mãos)."
    elif dpkg --compare-versions "$CAND_VER" lt "$LATEST_VER" 2>/dev/null; then
        ACTION="PINNED"   # latest é superior, mas caiu no gate GLIBC deste host
        DOWNGRADE_NOTE="latest $LATEST_VER rejeitada (GLIBC > $HOST_GLIBC); mantida a known-good $CAND_VER"
        # pinado com dano crítico de ARQUIVOS => repor arquivos da mesma versão
        if critical_damage; then
            ACTION="REINSTALL"
            warn "Instalação pinada ($CURRENT_VER) com dano crítico → REINSTALL da mesma versão."
        fi
    else
        ACTION="SKIP"
        # dano crítico de ARQUIVOS (binário/ícones) => reinstall da mesma versão
        if critical_damage; then
            ACTION="REINSTALL"
            warn "Instalação existente ($CURRENT_VER) com dano crítico → REINSTALL da mesma versão."
        fi
    fi
else
    if [ "$RUNTIME_OK" = 0 ]; then
        ACTION="REPAIR"
        DOWNGRADE_NOTE="downgrade $CURRENT_VER -> $CAND_VER (pty.node incompatível com GLIBC do host)"
    else
        ACTION="UPGRADE"
    fi
fi

# Label honesto da operação (R1: "UPGRADE" que era downgrade mentia no
# veredito e no history — agora write_state e veredito carregam o sufixo)
OP_LABEL="$ACTION"
if [ -n "$CURRENT_VER" ] && [ -n "$CAND_VER" ] \
   && dpkg --compare-versions "$CAND_VER" lt "$CURRENT_VER" 2>/dev/null; then
    OP_LABEL="DOWNGRADE($ACTION)"
fi

# v.261126a: sha256 do asset da versão JÁ instalada — o que o gate deste
# instalador registrou quando a avaliou (vazio se ele nunca a avaliou). É o
# único sha honesto a gravar em SKIP/PINNED: antes o `state` saía com o sha
# do candidato RECUSADO (sobrou em ASSET_SHA do resolve) rotulado como o
# asset instalado.
installed_asset_sha() {
    gate_cache_lookup "$CURRENT_VER" "$HOST_GLIBC" || return 0
    # v.261126b (R1): só serve um veredito COMPATÍVEL. Entrada "incompatível"
    # para esta versão fala de um asset que o gate RECUSOU — se a instalada
    # roda sã aqui, é outro asset (ex.: .deb consertado instalado à mão).
    [ -n "$CACHE_NEED" ] && glibc_ok "$CACHE_NEED" || return 0
    case "$CACHE_SHA" in ''|none) return 0 ;; esac
    printf '%s' "$CACHE_SHA"
}

case "$ACTION" in
    SKIP)
        skip "Pinokio $CURRENT_VER já é a melhor versão compatível. Prosseguindo com a auditoria de saúde."
        STAMP_TAG=""
        [ -f "$STATE_FILE" ] && STAMP_TAG=$(sed -n 's/^TAG=//p' "$STATE_FILE")
        if [ "$STAMP_TAG" != "v$CAND_VER" ]; then
            LATEST_TAG="v$CAND_VER"
            ASSET_NAME="$(asset_for_tag "$CAND_VER")"
            ASSET_SHA="$(installed_asset_sha)"
            write_state "adopted"
            info "Instalação existente adotada pelo instalador (state gravado)."
        fi
        ;;
    PINNED)
        skip "Mantendo $CURRENT_VER (latest $LATEST_VER reprovada no gate GLIBC deste host)."
        LATEST_TAG="v$CAND_VER"
        ASSET_NAME="$(asset_for_tag "$CAND_VER")"
        ASSET_SHA="$(installed_asset_sha)"
        write_state "pinned"
        warn "$DOWNGRADE_NOTE"
        ;;
    INSTALL)
        info "INSTALL: instalando do zero ($CAND_VER)."
        install_deb "$CAND_VER"
        write_state "install"
        ;;
    UPGRADE)
        info "UPGRADE: $CURRENT_VER → $CAND_VER (dados do usuário em ~/.pinokio são preservados)."
        install_deb "$CAND_VER"
        write_state "upgrade"
        ;;
    REINSTALL)
        info "REINSTALL: baixando a mesma versão ($CAND_VER) para repor arquivos danificados (dados preservados)."
        # o caminho SKIP seleciona o candidato SEM download — obter agora
        if [ ! -f "${DEB_FILE:-}" ]; then
            resolve_version "$CAND_VER"
            fetch_candidate || die "não foi possível obter o .deb de $CAND_VER para o REINSTALL."
        fi
        install_deb "$CAND_VER"
        write_state "reinstall"
        ;;
    REPAIR)
        info "REPAIR: instalação atual ($CURRENT_VER) quebrada em runtime — trocando por $CAND_VER."
        install_deb "$CAND_VER"
        write_state "repair"
        warn "$DOWNGRADE_NOTE"
        ;;
esac

# ===========================================================================
# AUTO-UPDATER — neutralização padrão (o updater interno derrubou a frota em
# 2026-11-21: dpkg -i do 8.4.0 incompatível + quitAndInstall). PINOKIO_ALLOW_
# AUTOUPDATE=1 restaura o nativo (e o backup do yml).
# ===========================================================================
APPUPDATE_YML="$SYS_ROOT/opt/Pinokio/resources/app-update.yml"
neutralize_updater() {
    if [ ! -f "$APPUPDATE_YML" ]; then
        warn "app-update.yml não encontrado ($APPUPDATE_YML) — nada a neutralizar."
        return 0
    fi
    # v.261121d (R1): idempotente de verdade — já neutralizado não gera
    # [HEAL] espúrio em cada rerun (só garante cache pending limpo).
    rm -rf "$HOME/.cache/pinokio-updater/pending" 2>/dev/null || true
    if grep -q 'pinokio-disabled-by-installer' "$APPUPDATE_YML" 2>/dev/null; then
        return 0
    fi
    cp -p "$APPUPDATE_YML" "$APPUPDATE_YML.installer-bak" 2>/dev/null || true
    sed -i 's/^repo: .*/repo: pinokio-disabled-by-installer-glibc-gate/' "$APPUPDATE_YML" 2>/dev/null || true
    healed "auto-updater interno neutralizado (updates só via instalador/pinokiocontrol --update; backup: app-update.yml.installer-bak)"
    echo "$(date '+%Y-%m-%d %H:%M:%S') neutralizado (gate GLIBC)" > "$STATE_DIR/autoupdate.disabled" 2>/dev/null || true
}
restore_updater() {
    if [ -f "$APPUPDATE_YML.installer-bak" ]; then
        cp -p "$APPUPDATE_YML.installer-bak" "$APPUPDATE_YML" 2>/dev/null \
            && healed "auto-updater nativo RESTAURADO (PINOKIO_ALLOW_AUTOUPDATE=1)."
    fi
    rm -f "$STATE_DIR/autoupdate.disabled" 2>/dev/null || true
}
if [ "${PINOKIO_ALLOW_AUTOUPDATE:-0}" = "1" ]; then
    info "PINOKIO_ALLOW_AUTOUPDATE=1 — mantendo/restaurando o auto-updater nativo."
    restore_updater
else
    neutralize_updater
fi

# ===========================================================================
# PINOKIOCONTROL — CLI local (controle sem depender de nada além da máquina)
# ===========================================================================
install_pinokiocontrol() {
    mkdir -p "$PC_BIN_DIR" || { warn "não consegui criar $PC_BIN_DIR — pinokiocontrol não instalado."; return 1; }
    cat > "$PC_BIN_DIR/pinokiocontrol" <<'PINOKIOCONTROL_EOF'
#!/bin/bash
# pinokiocontrol v.__SCRIPT_VERSION__ — controle local do Pinokio (padrão iamnexa)
# Instalado pelo install.sh do repo iamnexa-us/pinokiocontrol (fonte única — não editar à mão).
#
#   pinokiocontrol --status              versões (script/pinokio), ativo, portas, novidades
#   pinokiocontrol --update              atualiza script (Gitea) e/ou pinokio (GitHub, via
#                                        instalador com gate GLIBC) — idempotente
#   pinokiocontrol --start               força início (área VNC exigida)
#   pinokiocontrol --stop                força parada (persistent mantido)
#   pinokiocontrol --restart             stop + start
#   pinokiocontrol --persistent ON|OFF   volta (ou não) no próximo boot
#   pinokiocontrol --help | --version
#
# Overrides p/ sandbox/testes: PINOKIOCONTROL_STATE_DIR, PINOKIOCONTROL_OPT_DIR,
# PINOKIOCONTROL_GITEA_RAW, PINOKIOCONTROL_INSTALL_SCRIPT_URL, PINOKIOCONTROL_DISPLAY,
# PINOKIOCONTROL_SESSION_APPS_FILE, PINOKIOCONTROL_SKIP_GITHUB, PINOKIOCONTROL_SKIP_GITEA,
# VNCCONTROL_STATE_DIR. PINOKIO_GATE_CACHE_TTL: prazo (s) de um veredito
# "incompatível" em cache quando a API não informa o digest do asset.

VERSION="__SCRIPT_VERSION__"

STATE_DIR="${PINOKIOCONTROL_STATE_DIR:-/var/lib/pinokio-installer}"
BIN_DIR="${PINOKIOCONTROL_BIN_DIR:-/opt/pinokiocontrol/bin}"
GITEA_RAW="${PINOKIOCONTROL_GITEA_RAW:-https://raw.githubusercontent.com/iamnexa-us/pinokiocontrol/main}"
INSTALL_SCRIPT_URL="${PINOKIOCONTROL_INSTALL_SCRIPT_URL:-https://raw.githubusercontent.com/iamnexa-us/pinokiocontrol/main/install.sh}"
DISPLAY_VNC="${PINOKIOCONTROL_DISPLAY:-:99}"
OPT_PINOKIO="${PINOKIOCONTROL_OPT_DIR:-/opt/Pinokio}"
PINOKIO_HOME_CFG="$HOME/.pinokio/config.json"
PTY_REL="resources/app.asar.unpacked/node_modules/@homebridge/node-pty-prebuilt-multiarch/build/Release/pty.node"
# Gate do instalador (v.261126a): o cache de vereditos leva a IDENTIDADE do
# asset avaliado — mesmo formato e mesmas regras do install.sh. Um
# "incompatível" em cache só é levado a sério se for do asset publicado hoje.
GATE_CACHE="$STATE_DIR/glibc-gate.cache"
GATE_CACHE_TTL="${PINOKIO_GATE_CACHE_TTL:-86400}"
case "$GATE_CACHE_TTL" in ''|*[!0-9]*) GATE_CACHE_TTL=86400 ;; esac
case "$(uname -m)" in x86_64) DEB_ARCH=amd64 ;; aarch64|arm64) DEB_ARCH=arm64 ;; *) DEB_ARCH="" ;; esac
KNOWN_GOODS="__KNOWN_GOODS__"   # fallbacks do instalador (substituído na instalação, como a versão)

say() { echo "[pinokiocontrol] $*"; }
die() { echo "[pinokiocontrol ERRO] $*" >&2; exit 1; }

session_apps_file() {
    if [ -n "${PINOKIOCONTROL_SESSION_APPS_FILE:-}" ]; then
        printf '%s' "$PINOKIOCONTROL_SESSION_APPS_FILE"; return 0
    fi
    local d="${VNCCONTROL_STATE_DIR:-}"
    [ -z "$d" ] && [ -d /var/lib/vnccontrol ] && d=/var/lib/vnccontrol
    if [ -n "$d" ] && [ -d "$d" ]; then printf '%s/vnc.session-apps' "$d"; else printf '/dev-work/.env/vnc.session-apps'; fi
}

# "Nosso" = processo cujo EXECUTÁVEL mora no diretório do app — lido do magic
# link /proc/<pid>/exe (o sufixo " (deleted)" aparece quando o .deb foi
# trocado em disco depois que o processo subiu). v.261126b (R2): antes era
# substring na linha de comando (pgrep -f) — um tail/grep/watch que citasse
# "pinokio-bin" contava como nosso e o --stop o MATAVA.
app_dir_real() { realpath "${OPT_PINOKIO%/}" 2>/dev/null || printf '%s' "${OPT_PINOKIO%/}"; }
pinokio_pids() {
    local link exe want
    [ -d "$OPT_PINOKIO" ] || return 0
    want="$(app_dir_real)"
    while read -r link exe; do
        if [ -n "$exe" ]; then
            exe="${exe% (deleted)}"
            link="${link#/proc/}"
            if [ "${exe%/*}" = "$want" ]; then printf '%s\n' "${link%/exe}"; fi
        fi
    done < <(find /proc/[0-9]*/exe -maxdepth 0 -printf '%p %l\n' 2>/dev/null)
    return 0
}
is_running()   { [ -n "$(pinokio_pids)" ]; }

# v.261126b (R2): o app relançado NÃO pode ficar no cgroup de quem chamou
# (sessão SSH, serviço de agente…). O setsid tira da sessão, mas não do
# cgroup: com KillMode=control-group, parar ou reiniciar a unidade de quem
# chamou mata tudo que está lá — o Pinokio, o Caddy e o SearXNG iam junto e
# ninguém os relançava. Com systemd + root o lançamento roda dentro de um
# SCOPE próprio da system.slice; sem condições, lança como antes e avisa.
launch_isolation_probe() {   # 0 = dá para isolar (a sonda some na hora)
    command -v systemd-run >/dev/null 2>&1 || return 1
    [ -d /run/systemd/system ] || return 1
    [ "$(id -u)" = 0 ] || return 1
    LAUNCH_UNIT="pinokio-live-$(date +%s)-$$"
    systemd-run --quiet --scope --unit="pinokio-probe-$$" --slice=system.slice -- true 2>/dev/null
}
launch_isolated() {   # $@ = comando que sobe o app
    if [ -n "${LAUNCH_ISOLATION:-}" ]; then
        systemd-run --quiet --scope --unit="$LAUNCH_UNIT" --slice=system.slice -- "$@"
    else
        "$@"
    fi
}

# v.261121d (R2): captura em variável — curl morto com -w já imprime "000" e
# o "|| echo 000" encostava SEM newline => status exibia "000000".
http_code() {
    local c
    c=$(curl -m 4 -sS -o /dev/null -w '%{http_code}' "$1" 2>/dev/null) || c="000"
    printf '%s' "${c:-000}"
}

# v.261121d (R2): ancorar no bloco "access" — a 1ª chave "port" qualquer do
# config (ex.: tunnel.port) furava o status e o poll do --start.
# v.261121e: robusto a JSON minificado. v.261121f (R2 r3): o grep -oE é
# POR LINHA — no config PRETTY (o formato real do host) o bloco access
# spanning multi-linhas não casava e caía no default. tr -d '\n' antes:
# normaliza pretty E minificado num passe.
pinokio_port() {
    local p
    p=$(tr -d '\n' < "$PINOKIO_HOME_CFG" 2>/dev/null \
        | grep -oE '"access"[^}]*' \
        | grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+')
    printf '%s' "${p:-42000}"
}

# ldd inteiro no sed (sem "head" — SIGPIPE intermitente; ver nota no installer)
host_glibc() {
    local out=""
    out=$(ldd --version 2>/dev/null | sed -n '1s/.* \([0-9][0-9]*\.[0-9][0-9]*\)$/\1/p')
    printf '%s' "$out"
}
glibc_ok() {
    local need="$1" have top
    [ -n "$need" ] || return 0
    have=$(host_glibc); [ -n "$have" ] || return 0
    [ "$need" = "$have" ] && return 0
    top=$(printf '%s\n%s\n' "$need" "$have" | sort -V | tail -1)
    [ "$top" = "$have" ]
}
# Cache do veredito do gate (formato: "versao|glibc -> NEED sha256=… at=…";
# linha sem sha256/at = formato antigo). gate_cache_lookup preenche
# CACHE_NEED / CACHE_SHA / CACHE_AT.
gate_cache_lookup() {  # $1=versao $2=glibc → 0 = há entrada (1 = não há)
    local line kv ver_re glibc_re
    CACHE_NEED=""; CACHE_SHA=""; CACHE_AT=""
    [ -r "$GATE_CACHE" ] || return 1
    ver_re="${1//./\\.}"; glibc_re="${2//./\\.}"
    line=$(sed -n "s/^$ver_re|$glibc_re -> //p" "$GATE_CACHE" 2>/dev/null | tail -1) || line=""
    [ -n "$line" ] || return 1
    CACHE_NEED="${line%%[[:space:]]*}"
    for kv in ${line#"$CACHE_NEED"}; do
        case "$kv" in
            sha256=*) CACHE_SHA="${kv#sha256=}" ;;
            at=*)     CACHE_AT="${kv#at=}" ;;
        esac
    done
    case "$CACHE_AT" in *[!0-9]*) CACHE_AT="" ;; esac   # corrompida = sem data
    return 0
}
gate_cache_date() {
    [ -n "$CACHE_AT" ] || { printf 'data desconhecida'; return 0; }
    date -d "@$CACHE_AT" '+%d/%m/%Y %H:%M' 2>/dev/null || printf '%s' "$CACHE_AT"
}
# O "incompatível" em cache pode ser levado a sério? Só se for do MESMO
# asset publicado agora (sha256 da API), ou se for recente quando a API não
# deu identidade. Linha do formato antigo (sem identidade): nunca — o
# instalador reavalia. ($3 = sha256 publicado agora; vazio = desconhecido)
gate_cache_trusted() {  # $1=versao $2=glibc $3=sha256 publicado
    local age
    gate_cache_lookup "$1" "$2" || return 1
    [ -n "$CACHE_AT" ] || return 1
    if [ -n "${3:-}" ] && [ -n "$CACHE_SHA" ] && [ "$CACHE_SHA" != none ]; then
        [ "$3" = "$CACHE_SHA" ]
        return
    fi
    age=$(( $(date +%s) - CACHE_AT ))
    [ "$age" -ge 0 ] && [ "$age" -le "$GATE_CACHE_TTL" ]
}
# Latest no GitHub → GH_TAG (versão sem 'v') e GH_SHA (sha256 do .deb da nossa
# arquitetura = IDENTIDADE do asset publicado; vazio se a API não informar).
# Mesma extração do instalador: JSON colapsado numa linha e lido com sed
# (consome tudo — sem `head`, sem SIGPIPE intermitente).
gh_latest() {
    GH_TAG=""; GH_SHA=""
    local json joined url
    json=$(curl -m 8 -fsSL -H 'Accept: application/vnd.github+json' \
          -H 'User-Agent: pinokiocontrol/1.0' \
          https://api.github.com/repos/pinokiocomputer/pinokio/releases/latest 2>/dev/null) || return 1
    joined=$(printf '%s' "$json" | tr -d '\n\r')
    GH_TAG=$(printf '%s' "$joined" | grep -oE '"tag_name": *"[^"]*"' \
             | sed -n -e 's/.*"tag_name": *"v\?//' -e 's/"$//' -e '1p')
    [ -n "$GH_TAG" ] || return 1
    [ -n "$DEB_ARCH" ] || return 0
    url=$(printf '%s' "$joined" | grep -oE '"browser_download_url": *"[^"]*"' \
          | sed -e 's/.*"browser_download_url": *"//' -e 's/"$//' \
          | grep -E "/Pinokio_${GH_TAG//./\\.}_${DEB_ARCH}\\.deb\$" | tail -1) || url=""
    [ -n "$url" ] || return 0
    GH_SHA=$(printf '%s' "$joined" \
             | grep -oE "\"digest\": *\"sha256:[0-9a-f]+\"[^{}]*\"browser_download_url\": *\"$url\"" \
             | sed -n 's/.*"digest": *"sha256:\([0-9a-f]*\)".*/\1/p') || GH_SHA=""
    return 0
}
runtime_glibc_ok() {
    local f="$OPT_PINOKIO/$PTY_REL" need
    [ -f "$f" ] && command -v objdump >/dev/null 2>&1 || return 0
    need=$(objdump -T "$f" 2>/dev/null | grep -oE 'GLIBC_2\.[0-9]+' | sort -uV | tail -1)
    glibc_ok "${need#GLIBC_}"
}

persistent_state() { cat "$STATE_DIR/persistent" 2>/dev/null || echo ON; }

cmd_status() {
    echo "pinokiocontrol $VERSION"
    if [ "${PINOKIOCONTROL_SKIP_GITEA:-0}" = 1 ]; then
        echo "script-gitea: (skip por override)"
    else
        local lv
        lv=$(curl -m 8 -fsSL "$GITEA_RAW/VERSION" 2>/dev/null || true)
        if [ -n "$lv" ]; then
            if [ "$lv" = "$VERSION" ]; then echo "script-gitea: $lv (atual)"
            else echo "script-gitea: $lv (NOVA disponível — --update)"; fi
        else
            echo "script-gitea: inacessível (rede?)"
        fi
    fi
    local inst
    inst=$(dpkg-query -W -f='${Version}' pinokio 2>/dev/null || true)
    echo "pinokio-instalado: ${inst:-NENHUM}"
    if [ "${PINOKIOCONTROL_SKIP_GITHUB:-0}" = 1 ]; then
        echo "pinokio-github: (skip por override)"
    else
        # v.261126a: o "INCOMPATÍVEL" do cache só vale para o asset que o gate
        # avaliou. Cache sem identidade (formato antigo) ou de outro asset é
        # denunciado — antes ele valia para sempre, mesmo depois de o upstream
        # substituir o .deb da mesma tag.
        if gh_latest; then
            if [ "$GH_TAG" = "$inst" ] && runtime_glibc_ok; then
                # a latest já é a instalada e ela RODA neste host: é "atual",
                # faça o que fizer o cache (chave velha, digest trocado...)
                echo "pinokio-github: $GH_TAG (atual)"
            elif gate_cache_lookup "$GH_TAG" "$(host_glibc)" && [ -n "$CACHE_NEED" ] && ! glibc_ok "$CACHE_NEED"; then
                if gate_cache_trusted "$GH_TAG" "$(host_glibc)" "$GH_SHA"; then
                    echo "pinokio-github: $GH_TAG (latest INCOMPATÍVEL com este host — gate GLIBC mantém a ${inst:-versão instalada}; avaliado em $(gate_cache_date), asset ${CACHE_SHA:0:12})"
                else
                    echo "pinokio-github: $GH_TAG (cache do gate ANTIGO: não identifica o asset publicado hoje — --update reavalia antes de decidir)"
                fi
            elif [ "$GH_TAG" = "$inst" ]; then echo "pinokio-github: $GH_TAG (atual)"
            else echo "pinokio-github: $GH_TAG (NOVA — --update aplica via instalador c/ gate GLIBC)"; fi
        else
            echo "pinokio-github: inacessível (rede?)"
        fi
    fi
    if is_running; then echo "ativo: SIM (pids: $(pinokio_pids | xargs echo))"
    else echo "ativo: NÃO"; fi
    local p
    p=$(pinokio_port)
    echo "porta-ui: $p -> http $(http_code "http://127.0.0.1:$p/")"
    echo "searxng-8888: http $(http_code 'http://127.0.0.1:8888/search?q=x&format=json') (porta da rede — nunca reconfigurar)"
    if [ -f "$OPT_PINOKIO/$PTY_REL" ]; then
        if runtime_glibc_ok; then echo "glibc-compat: OK"; else echo "glibc-compat: INCOMPATÍVEL (rode --update para reparar)"; fi
    else
        echo "glibc-compat: n/d (pinokio não instalado)"
    fi
    # v.261121d (R2/R3): cruzar marker × lista real — divergência denunciada
    local ps_f inlist
    ps_f=$(session_apps_file)
    if [ -f "$ps_f" ]; then
        case " $( { grep -vE '^[[:space:]]*(#|$)' "$ps_f" 2>/dev/null || true; } | tr '\n' ' ') " in
            *" pinokio "*) inlist=1 ;; *) inlist=0 ;;
        esac
    else
        inlist=1   # arquivo ausente => defaults do vnccontrol (inclui pinokio)
    fi
    local divg=""
    if { [ "$(persistent_state)" = ON ] && [ "$inlist" = 0 ]; } || { [ "$(persistent_state)" = OFF ] && [ "$inlist" = 1 ]; }; then
        divg=" ⚠ DIVERGENTE: lista $( [ "$inlist" = 1 ] && echo 'com' || echo 'sem') pinokio em $ps_f — rode --persistent $(persistent_state)"
    fi
    echo "persistente: $(persistent_state) (próximo boot)$divg"
    return 0
}

vnc_area_up() {
    # v.261121d (R2): mesmo fallback do instalador (pgrep do Xvfb) — sem
    # xdpyinfo o die enganoso dizia "área VNC inativa" com a área de pé.
    if command -v xdpyinfo >/dev/null 2>&1; then
        DISPLAY="$DISPLAY_VNC" timeout 10 xdpyinfo >/dev/null 2>&1
    else
        pgrep -f "[X]vfb $DISPLAY_VNC" >/dev/null 2>&1
    fi
}

ensure_registered() {
    # v.261121e (R2/R3 r2): marker OFF => NÃO re-registrar — o --start
    # religava o boot silenciosamente (contrato: persistent diz respeito
    # ao próximo boot). Retorna 1 para o chamador usar lançamento direto.
    if [ "$(persistent_state)" = OFF ]; then
        return 1
    fi
    local f listed
    f=$(session_apps_file)
    if [ ! -f "$f" ]; then
        if printf 'nvpair\npinokio\nfreetoken\n' > "$f" 2>/dev/null; then
            say "criado $f (defaults do vnccontrol + pinokio)"
        else
            say "aviso: não consegui criar $f (permissão?)"
        fi
        return 0
    fi
    listed=$( { grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null || true; } | tr '\n' ' ')
    case " $listed " in
        *" pinokio "*) : ;;
        *)
            [ -n "$(tail -c 1 "$f" 2>/dev/null)" ] && printf '\n' >> "$f" 2>/dev/null || true
            if printf '%s\n' pinokio >> "$f" 2>/dev/null; then
                say "session-app 'pinokio' acrescentado a $f"
            else
                say "aviso: falha ao acrescentar 'pinokio' em $f"
            fi
            ;;
    esac
    return 0
}

# Lançamento DIRETO (sem o vnccontrol): env de sessão + scope próprio. É o
# caminho quando não há vnccontrol, quando --persistent é OFF, e a rede de
# segurança quando o vnccontrol não sobe o app (ver cmd_start).
direct_launch() {
    # v.261121f (R2): sem binário não há o que lançar — o & mascarava a
    # falha e o poll decidia sozinho (falso-ativo na porta default)
    [ -x "$OPT_PINOKIO/pinokio" ] \
        || die "pinokio não instalado em $OPT_PINOKIO — rode: pinokiocontrol --update"
    local dbusa="" logf="$STATE_DIR/pinokio.log"
    [ -s /var/lib/vnccontrol/vnc.dbus ] && dbusa="DBUS_SESSION_BUS_ADDRESS=$(cat /var/lib/vnccontrol/vnc.dbus 2>/dev/null)"
    mkdir -p "$STATE_DIR" 2>/dev/null || logf=/dev/null
    local -a launch=("$OPT_PINOKIO/pinokio" --no-sandbox)
    [ -z "${LAUNCH_ISOLATION:-}" ] || launch=(systemd-run --quiet --scope --unit="$LAUNCH_UNIT" --slice=system.slice -- "${launch[@]}")
    env -u DBUS_SESSION_BUS_ADDRESS ${dbusa:+$dbusa} \
        DISPLAY="$DISPLAY_VNC" XDG_SESSION_TYPE=x11 \
        setsid nohup "${launch[@]}" >>"$logf" 2>&1 8>&- 9>&- &
}
cmd_start() {
    if is_running; then say "pinokio já está ativo"; return 0; fi
    vnc_area_up || die "área VNC ($DISPLAY_VNC) inativa — suba com: vnccontrol --on"
    LAUNCH_ISOLATION=""; LAUNCH_UNIT=""; DIRECT_LAUNCH=0
    if launch_isolation_probe; then
        LAUNCH_ISOLATION=1
    else
        say "aviso: sem isolamento de cgroup (systemd-run indisponível) — o app fica no cgroup de quem chamou"
    fi
    if ensure_registered && command -v vnccontrol >/dev/null 2>&1; then
        say "iniciando via 'vnccontrol --session-apps start' (idempotente; env+logs corretos)"
        # 8>&-: o vnccontrol lança ring-consumers eternos — sem isso o nosso
        # flock (fd 8) vazava para eles e ficava preso para sempre.
        # timeout (v.261126b, R2): o vnccontrol espera o X e o painel sem
        # limite próprio — o persist_autostart do instalador já usava 180 s.
        launch_isolated timeout 150 vnccontrol --session-apps start 8>&- \
            || say "aviso: vnccontrol retornou erro"
        # v.261126b (achado no E2E, em produção): o vnccontrol decide "já
        # ativo" por SUBSTRING na linha de comando ([p]inokio-bin) — qualquer
        # processo que cite o nome (um shell de agente, um tail, um grep) e
        # ele NÃO sobe o app, que ficaria fora do ar depois de um --restart.
        # Espera o processo NOSSO aparecer (o wrapper é um sh antes do exec);
        # se não vier em ~5 s, sobe direto.
        local _ waited=0
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            is_running && { waited=1; break; }
            sleep 0.5
        done
        if [ "$waited" != 1 ]; then
            say "o vnccontrol não subiu o app (marcou 'já ativo' por outro processo?) — lançamento direto"
            direct_launch
            DIRECT_LAUNCH=1
        fi
    else
        if [ "$(persistent_state)" = OFF ]; then
            say "persistent=OFF — lançamento direto SEM registrar no boot (lista intocada)"
        else
            say "vnccontrol ausente — lançamento direto"
        fi
        direct_launch
        DIRECT_LAUNCH=1
    fi
    local p i loghint="/var/lib/vnccontrol/session-apps/pinokio.log"
    # v.261121f (R2): loghint também no branch OFF (o lançamento lá é direto;
    # o die apontava o log do vnccontrol que não foi usado)
    if [ "${DIRECT_LAUNCH:-0}" = 1 ]; then
        loghint="$STATE_DIR/pinokio.log"
    fi
    p=$(pinokio_port)
    for i in $(seq 1 40); do
        [ "$(http_code "http://127.0.0.1:$p/")" = 200 ] && { say "ativo (porta $p)"; return 0; }
        sleep 1
    done
    die "pinokio não respondeu em 40s na porta $p — veja $loghint"
}

cmd_stop() {
    local pids i
    pids=$(pinokio_pids)
    [ -z "$pids" ] && { say "pinokio já está parado"; return 0; }
    say "parando (TERM): $(echo $pids)"
    kill $pids 2>/dev/null || true
    for i in $(seq 1 10); do sleep 1; [ -z "$(pinokio_pids)" ] && break; done
    pids=$(pinokio_pids)
    if [ -n "$pids" ]; then
        say "KILL remanescentes: $(echo $pids)"
        kill -9 $pids 2>/dev/null || true
        sleep 1
    fi
    is_running && die "processos sobreviveram ao stop"
    say "parado (persistent=$(persistent_state) preservado — decide o próximo boot)"
    return 0
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_persistent() {  # $1 = ON|OFF
    local want f keep
    want=$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')
    case "$want" in
        ON|OFF) ;;
        *) echo "uso: pinokiocontrol --persistent ON|OFF" >&2; return 1 ;;
    esac
    f=$(session_apps_file)
    if [ ! -f "$f" ]; then
        if [ "$want" = ON ]; then printf 'nvpair\npinokio\nfreetoken\n' > "$f" 2>/dev/null
        else printf 'nvpair\nfreetoken\n' > "$f" 2>/dev/null; fi \
            || die "não consegui criar $f"
    else
        # v.261121d (R2): normalizar CR (CRLF deixava "pinokio\r" residual)
        # e MORRER se a gravação falhar (antes: rc=0 de sucesso falso com
        # ENOSPC/ro/immutable — lista intocada + marker mentindo).
        keep=$(sed 's/\r$//' "$f" 2>/dev/null | grep -vx pinokio || true)
        if [ "$want" = ON ]; then
            printf '%s\npinokio\n' "$keep" > "$f.pc.tmp" 2>/dev/null && mv -f "$f.pc.tmp" "$f" 2>/dev/null \
                || die "falha ao gravar a lista de session-apps ($f) — disco/permissão?"
        else
            printf '%s\n' "$keep" > "$f.pc.tmp" 2>/dev/null && mv -f "$f.pc.tmp" "$f" 2>/dev/null \
                || die "falha ao gravar a lista de session-apps ($f) — disco/permissão?"
        fi
    fi
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    echo "$want" > "$STATE_DIR/persistent" 2>/dev/null \
        || die "falha ao gravar o marker ($STATE_DIR/persistent) — disco/permissão?"
    if [ "$want" = ON ]; then say "persistente=ON — pinokio volta no próximo boot (lista: $f)"
    else say "persistente=OFF — pinokio NÃO volta no próximo boot (lista: $f)"; fi
    return 0
}

cmd_update() {
    [ "$(id -u)" -eq 0 ] || die "rode como root (sudo)"
    local lv tag inst need=0 why="" unverified=0 pub_sha="" gate_note="" kg=""
    # v.261121e (R2): honrar PINOKIOCONTROL_SKIP_GITEA também no update
    if [ "${PINOKIOCONTROL_SKIP_GITEA:-0}" != 1 ]; then
        lv=$(curl -m 8 -fsSL "$GITEA_RAW/VERSION" 2>/dev/null || true)
        [ -z "$lv" ] && unverified=1
        if [ -n "$lv" ] && [ "$lv" != "$VERSION" ]; then need=1; why="script $VERSION->$lv"; fi
    fi
    if [ "${PINOKIOCONTROL_SKIP_GITHUB:-0}" != 1 ]; then
        inst=$(dpkg-query -W -f='${Version}' pinokio 2>/dev/null || true)
        tag=""; pub_sha=""
        # v.261126a: a MESMA consulta traz o digest do .deb publicado — a
        # identidade do asset. Só se levanta a sério um "incompatível" do
        # cache se ele for DESSE asset (gate_cache_trusted); cache do formato
        # antigo ou de outro asset manda reavaliar. Antes o atalho respondia
        # "já atualizado" (rc=0) para sempre, com a latest nunca reavaliada.
        if gh_latest; then tag="$GH_TAG"; pub_sha="$GH_SHA"; else unverified=1; fi
        if [ -n "$tag" ] && [ "$tag" != "$inst" ]; then
            gate_cache_lookup "$tag" "$(host_glibc)"
            if [ -n "$CACHE_NEED" ] && ! glibc_ok "$CACHE_NEED"; then
                if gate_cache_trusted "$tag" "$(host_glibc)" "$pub_sha"; then
                    # v.261126b (R1): "nada a fazer" só quando não há mesmo o que
                    # fazer. Sem Pinokio, ou com um mais antigo que a known-good,
                    # o instalador tem trabalho (INSTALL / UPGRADE p/ known-good)
                    # — antes saía "já atualizado (… pinokio NENHUM)".
                    kg="$(printf '%s\n' $KNOWN_GOODS | sort -V | tail -1)"
                    if [ -z "$inst" ] || { [ -n "$kg" ] && dpkg --compare-versions "$inst" lt "$kg" 2>/dev/null; }; then
                        need=1; why="${why:+$why; }pinokio ${inst:-nenhum}->$kg (known-good; latest $tag recusada pelo gate)"
                    else
                        gate_note="latest $tag recusada pelo gate (exige GLIBC $CACHE_NEED > $(host_glibc); avaliado em $(gate_cache_date), asset ${CACHE_SHA:0:12}) — nada a fazer"
                    fi
                else
                    need=1; why="${why:+$why; }pinokio ${inst:-nenhum}->$tag (cache do gate não identifica o asset publicado — reavaliando)"
                fi
            else
                need=1; why="${why:+$why; }pinokio ${inst:-nenhum}->$tag (sujeito ao gate GLIBC)"
            fi
        fi
    fi
    if ! runtime_glibc_ok; then
        need=1; why="${why:+$why; }instalado incompatível com GLIBC do host (reparo)"
    fi
    if [ "$need" = 1 ]; then
        say "atualizando via instalador oficial ($why)"
        # v.261121d (R2 CRÍTICO): liberar e FECHAR o lock ANTES — o instalador
        # spawn o vnccontrol (rings eternos) que herdaria o fd 8.
        # v.261121e: redirect no BLOCO (exec-redirect permanente matava stderr).
        flock -u 8 2>/dev/null || true
        { exec 8>&-; } 2>/dev/null || true
        # v.261121e (R2 sério): baixar ANTES de executar — curl falho via <(...)
        # entregava script VAZIO e o bash "executava nada" com rc=0 (sucesso
        # falso de update na frota com Gitea fora).
        local itmp irc
        itmp=$(mktemp) || die "não foi possível criar temporário p/ o instalador"
        if ! curl -m 60 -fsSL "$INSTALL_SCRIPT_URL" -o "$itmp"; then
            rm -f "$itmp"
            die "não baixou o instalador ($INSTALL_SCRIPT_URL — rede/Gitea?)"
        fi
        # v.261121f (R1): corpo VAZIO com HTTP 200 (proxy em manutenção,
        # conexão fechada cedo) — último vetor de rc=0 falso: bash roda nada.
        if [ ! -s "$itmp" ] || ! grep -q 'Instalador do Pinokio' "$itmp" 2>/dev/null; then
            rm -f "$itmp"
            die "instalador baixado vazio/inválido ($INSTALL_SCRIPT_URL)"
        fi
        bash "$itmp" 8>&- 9>&-
        irc=$?
        rm -f "$itmp"
        exit "$irc"
    fi
    if [ "$unverified" = 1 ]; then
        # v.261121d (R2): rede morta NÃO é "já atualizado" (mascara queda de
        # Gitea/GitHub na frota) — honestidade e rc=1.
        say "NÃO FOI POSSÍVEL VERIFICAR atualizações (Gitea/GitHub inacessíveis) — nada alterado"
        return 1
    fi
    say "já atualizado (verificado agora: script $VERSION · pinokio $(dpkg-query -W -f='${Version}' pinokio 2>/dev/null || echo NENHUM))"
    # v.261126a: quando a latest fica para trás por decisão do gate, dizer
    # qual veredito é esse e de quando — "já atualizado" sozinho mentia.
    [ -z "$gate_note" ] || say "$gate_note"
    return 0
}

usage() {
    cat <<USAGE
pinokiocontrol $VERSION — controle local do Pinokio (padrão iamnexa)

  --status              versões (script no Gitea + pinokio no GitHub), ativo,
                        portas (UI + SearXNG :8888), compatibilidade GLIBC,
                        estado persistente
  --update              atualiza script (Gitea) e/ou pinokio (GitHub) — sempre
                        via instalador oficial (gate GLIBC + fallback); idempotente
  --start               força início (área VNC :99 exigida)
  --stop                força parada (flag persistent preservada)
  --restart             stop + start
  --persistent ON|OFF   se volta ativo no próximo boot (default do lab: ON)
  --help                esta ajuda
  --version             versão do script

Regras da rede: SearXNG é SEMPRE acessado em :8888 (Home Server do Pinokio) —
este script nunca reconfigura portas. Updates do app são geridos pelo
instalador (o auto-updater interno é neutralizado por padrão).
USAGE
}

with_lock() {
    # v.261121c: duas lições:
    # 1) NUNCA "exec 8>file 2>/dev/null" — o redirect de stderr em exec é
    #    PERMANENTE: die() ficava invisível (rc=1 silencioso no --restart).
    # 2) O lock NÃO pode vazar para filhos de longa vida: o --start delega
    #    ao vnccontrol, que lança ring-consumers eternos — eles herdavam o
    #    fd 8 e seguravam o flock para sempre (o --restart seguinte morria
    #    no flock -n). Os spawns de cmd_start fecham o 8 explicitamente.
    # v.261121d (R2): distinguir "flock ausente" de "lock ocupado".
    command -v flock >/dev/null 2>&1 \
        || die "flock não encontrado (util-linux) — instale com: apt-get install -y util-linux"
    local f="$STATE_DIR/pinokiocontrol.lock"
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    if ! exec 8>"$f"; then
        die "não foi possível abrir o lock: $f"
    fi
    flock -n 8 || die "outra operação pinokiocontrol em andamento (lock: $f)"
    "$@"
}

main() {
    case "${1:-}" in
        --status)    cmd_status ;;
        --start)     with_lock cmd_start ;;
        --stop)      with_lock cmd_stop ;;
        --restart)   with_lock cmd_restart ;;
        --persistent) shift; with_lock cmd_persistent "${1:-}" ;;
        --update)    with_lock cmd_update ;;
        --help|-h|help) usage ;;
        --version)   echo "pinokiocontrol v$VERSION" ;;
        *) usage >&2; return 1 ;;
    esac
}

main "$@"
PINOKIOCONTROL_EOF
    local rc=$?
    [ $rc -eq 0 ] || return $rc
    local kg_sed
    kg_sed=$(printf '%s' "$KNOWN_GOODS" | sed -e 's/[&/\]/\\&/g')
    sed -i -e "s/__SCRIPT_VERSION__/$SCRIPT_VERSION/g" -e "s/__KNOWN_GOODS__/$kg_sed/g" "$PC_BIN_DIR/pinokiocontrol"
    # o placeholder tem mesmo sumir: um __KNOWN_GOODS__ literal deixaria o
    # --update sem fallback e compararia versões contra lixo
    grep -q '__[A-Z_]*__' "$PC_BIN_DIR/pinokiocontrol" 2>/dev/null \
        && warn "placeholder não substituído no pinokiocontrol instalado ($PC_BIN_DIR/pinokiocontrol)." || true
    chmod 755 "$PC_BIN_DIR/pinokiocontrol"
    mkdir -p "$PC_LINK_DIR" 2>/dev/null || true
    ln -sf "$PC_BIN_DIR/pinokiocontrol" "$PC_LINK" 2>/dev/null \
        || warn "symlink $PC_LINK falhou (use $PC_BIN_DIR/pinokiocontrol)"
    printf '%s\n' "$SCRIPT_VERSION" > "$PC_BIN_DIR/../VERSION"
    ok "pinokiocontrol v$SCRIPT_VERSION → $PC_BIN_DIR/pinokiocontrol (+ $PC_LINK)"
    # primeira linha do --version é sagrada (parsers externos)
    local first
    first=$("$PC_BIN_DIR/pinokiocontrol" --version 2>/dev/null | head -1)
    [ "$first" = "pinokiocontrol v$SCRIPT_VERSION" ] \
        || warn "saída inesperada de --version: '$first'"
}

# ===========================================================================
# HEALTH CHECK & SELF-HEAL — roda SEMPRE (inclusive em SKIP): "instalado"
# só vale se estiver SAUDÁVEL. Cada item inválido é consertado na hora;
# o que não dá para consertar sem o .deb vira ressalva no veredito final.
# (app_bin_ok / sandbox_present / icons_ok / critical_damage: definidos antes
#  do bloco de decisão, que também os utiliza.)
# ===========================================================================
health_check_and_heal() {
    info "Auditoria de saúde da instalação..."

    # ---- 1. Estado do pacote dpkg ----
    local st
    st=$(dpkg-query -W -f='${Status}' "$PKG" 2>/dev/null || true)
    if [ -n "$(installed_version)" ]; then
        ok "Pacote dpkg íntegro: $PKG $(installed_version) ($st)"
    else
        warn "Pacote $PKG não está em estado 'install ok installed' ($st)."
    fi

    # ---- 2. Binário principal ----
    if app_bin_ok; then
        ok "Binário principal: $APP_BIN (executável)"
    else
        warn "Binário ausente/não executável: $APP_BIN (dano crítico — reinstall necessário)."
    fi

    # ---- 3. Compatibilidade runtime (pty.node x GLIBC do host) ----
    if installed_glibc_ok; then
        ok "pty.node compatível com GLIBC do host ($HOST_GLIBC)."
    else
        warn "pty.node INCOMPATÍVEL com GLIBC do host — app não sobe (rode de novo p/ REPAIR)."
    fi

    # ---- 4. Permissão do chrome-sandbox (regra do postinst oficial) ----
    local have_perm
    if [ -f "$SANDBOX_BIN" ]; then
        have_perm="$(stat -c %a "$SANDBOX_BIN")"
        if [ "$have_perm" = "$SANDBOX_WANT_PERM" ]; then
            ok "chrome-sandbox: $SANDBOX_BIN ($have_perm) — igual ao postinst oficial"
        else
            if chmod "$SANDBOX_WANT_PERM" "$SANDBOX_BIN" 2>/dev/null; then
                healed "chrome-sandbox: $have_perm → $SANDBOX_WANT_PERM (regra do postinst oficial)"
            else
                warn "chrome-sandbox com permissão $have_perm (esperada $SANDBOX_WANT_PERM) e não foi possível corrigir."
            fi
        fi
    else
        warn "chrome-sandbox ausente: $SANDBOX_BIN (dano crítico — reinstall necessário)."
    fi

    # ---- 5. Launcher /usr/bin/pinokio ----
    local resolved
    resolved="$(readlink -f "$LAUNCHER" 2>/dev/null || true)"
    if [ -x "$LAUNCHER" ] && [ "$resolved" = "$APP_BIN" ]; then
        ok "Launcher: $LAUNCHER → $APP_BIN"
    else
        healed "Launcher $LAUNCHER inválido (resolvia para: ${resolved:-nada}); recriando via update-alternatives..."
        mkdir -p "$(dirname "$LAUNCHER")" 2>/dev/null || true
        if [ -e "$LAUNCHER" ] && [ ! -L "$LAUNCHER" ]; then
            rm -f "$LAUNCHER"   # arquivo comum no lugar do symlink (instalação antiga quebrada)
        fi
        update-alternatives --install "$LAUNCHER" pinokio "$APP_BIN" 100 2>/dev/null \
            || ln -sf "$APP_BIN" "$LAUNCHER" 2>/dev/null \
            || warn "Não foi possível recriar o launcher $LAUNCHER."
    fi

    # ---- 6. Desktop entry (validação por CONTEÚDO) ----
    local line desktop_ok=1
    if [ -f "$DESKTOP_FILE" ]; then
        for line in "${DESKTOP_REQUIRED_LINES[@]}"; do
            grep -qxF "$line" "$DESKTOP_FILE" || desktop_ok=0
        done
    else
        desktop_ok=0
    fi
    if [ "$desktop_ok" = 1 ]; then
        ok "Desktop entry: $DESKTOP_FILE (conteúdo confere)"
    else
        healed "Desktop entry ausente/corrompido; recriando (mesmo conteúdo do .deb oficial)..."
        mkdir -p "$(dirname "$DESKTOP_FILE")" 2>/dev/null || true
        cat > "$DESKTOP_FILE" <<'DESKEOF' || warn "Não foi possível recriar o desktop entry."
[Desktop Entry]
Name=Pinokio
Exec=/opt/Pinokio/pinokio %U
Terminal=false
Type=Application
Icon=pinokio
StartupWMClass=Pinokio
Comment=pinokio
MimeType=x-scheme-handler/pinokio;
Categories=Utility;
DESKEOF
        chmod 644 "$DESKTOP_FILE" 2>/dev/null || true
    fi

    # ---- 7. Ícones hicolor ----
    if icons_ok; then
        ok "Ícones hicolor presentes ($ICON_NAME)"
    else
        warn "Ícone hicolor ausente ($ICON_NAME) — dano crítico (reinstall repõe)."
    fi

    # ---- 8. Integridade de arquivos do pacote (advisory) ----
    local verify_out
    verify_out="$(dpkg -V "$PKG" 2>/dev/null || true)"
    if [ -n "$verify_out" ]; then
        warn "dpkg -V reportou divergências em $PKG (o app-update do .deb oficial pode explicar; verifique):"
        printf '%s\n' "$verify_out" | sed 's/^/         /'
    fi

    # ---- 9. Caches de desktop/ícones (best-effort) ----
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$SYS_ROOT/usr/share/applications" 2>/dev/null || true
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -q -t -f "$SYS_ROOT/usr/share/icons/hicolor" 2>/dev/null || true
    fi
}

health_check_and_heal

# ===========================================================================
# PINOKIOCONTROL — instalar/depois de saúde OK
# ===========================================================================
install_pinokiocontrol || true

# ===========================================================================
# PERSISTÊNCIA / AUTOSTART (padrão do lab — área VNC gerenciada pelo
# vnccontrol; apps de família sobem como "session-apps", com --no-sandbox
# aplicado pelo próprio vnccontrol, sem depender de login de usuário)
# ===========================================================================
vnccontrol_bin() {
    local f
    # v.261121d (R1/R3): rotas sob $SYS_ROOT — sandbox hermético (sem isso,
    # um "teste" podia executar o vnccontrol REAL do host de produção)
    for f in "$SYS_ROOT/usr/local/bin/vnccontrol" "$SYS_ROOT/usr/bin/vnccontrol" "$SYS_ROOT/dev-work/bin/vnccontrol"; do
        [ -x "$f" ] && { printf '%s' "$f"; return 0; }
    done
    command -v vnccontrol 2>/dev/null || true
}

vnc_area_up() {
    if command -v xdpyinfo >/dev/null 2>&1; then
        DISPLAY="$VNC_DISPLAY" timeout 10 xdpyinfo >/dev/null 2>&1
    else
        pgrep -f "[X]vfb $VNC_DISPLAY" >/dev/null 2>&1
    fi
}

# Dá para pôr processos num scope próprio da system.slice? (systemd + root; a
# sonda cria e apaga um scope vazio na hora.) v.261126b (R2).
systemd_scope_available() {
    command -v systemd-run >/dev/null 2>&1 || return 1
    [ -d /run/systemd/system ] || return 1
    [ "$(id -u)" = 0 ] || return 1
    systemd-run --quiet --scope --unit="pinokio-probe-$$" --slice=system.slice -- true 2>/dev/null
}

# ---------------------------------------------------------------------------
# REINÍCIO após troca de arquivos (v.261126a). UPGRADE/REPAIR/REINSTALL
# trocam os binários EM DISCO; o processo antigo seguia rodando o build
# antigo pelos inodes antigos — e passava a ler recursos novos do disco —
# até alguém reiniciar, com o veredito dizendo "UPGRADE concluído". Agora:
# se o app estava em execução, ele volta NOVO no fim da instalação.
# Só conta como "em execução" um processo cujo EXECUTÁVEL mora no NOSSO
# APP_DIR (v.261126b, R2: antes era substring na linha de comando — um
# tail/grep/watch que citasse "pinokio-bin" contava como "alheio" e
# bloqueava o reinício, com rc=0 e "UPGRADE concluído").
# ---------------------------------------------------------------------------
app_dir_real() { realpath "${APP_DIR%/}" 2>/dev/null || printf '%s' "${APP_DIR%/}"; }
managed_app_pids() {  # → MANAGED_PIDS: pids cujo executável vive em APP_DIR (vazio = nenhum)
    local link exe want
    MANAGED_PIDS=""
    [ -d "$APP_DIR" ] || return 0
    want="$(app_dir_real)"
    while read -r link exe; do
        if [ -n "$exe" ]; then
            exe="${exe% (deleted)}"          # .deb trocado depois que o processo subiu
            link="${link#/proc/}"
            if [ "${exe%/*}" = "$want" ]; then MANAGED_PIDS="$MANAGED_PIDS${link%/exe} "; fi
        fi
    done < <(find /proc/[0-9]*/exe -maxdepth 0 -printf '%p %l\n' 2>/dev/null)
    return 0
}
restart_app_after_swap() {
    RESTART_STATUS="sem-troca"; RESTART_FAIL=""
    case "${ACTION:-}" in UPGRADE|REPAIR|REINSTALL) ;; *) return 0 ;; esac
    if [ "$SKIP_AUTOSTART" = "1" ]; then
        RESTART_STATUS="pulado"
        managed_app_pids
        if [ -n "$MANAGED_PIDS" ]; then
            warn "PINOKIO_SKIP_AUTOSTART=1 — o Pinokio em execução (pids ${MANAGED_PIDS% }) NÃO foi reiniciado e segue no build antigo; rode: pinokiocontrol --restart"
        else
            info "PINOKIO_SKIP_AUTOSTART=1 — nenhum Pinokio em execução; nada a reiniciar."
        fi
        return 0
    fi
    managed_app_pids
    if [ -z "$MANAGED_PIDS" ]; then RESTART_STATUS="não-rodava"; return 0; fi
    if [ ! -x "$PC_BIN_DIR/pinokiocontrol" ]; then
        RESTART_STATUS="falhou"
        RESTART_FAIL="o Pinokio antigo (pids ${MANAGED_PIDS% }) SEGUE no ar no build antigo: pinokiocontrol não foi instalado — reinicie manualmente (pare esses pids e suba com: vnccontrol --session-apps start)"
        warn "$RESTART_FAIL."
        return 1
    fi
    if ! vnc_area_up; then
        RESTART_STATUS="falhou"
        RESTART_FAIL="o Pinokio antigo (pids ${MANAGED_PIDS% }) SEGUE no ar no build antigo: a área VNC ($VNC_DISPLAY) está desligada e não há como relançá-lo — suba a área (vnccontrol --on) e rode: pinokiocontrol --restart"
        warn "$RESTART_FAIL."
        return 1
    fi
    info "Reiniciando o Pinokio (pids ${MANAGED_PIDS% }) para valer a versão instalada ($(installed_version))..."
    # 9>&- / 8>&-: nenhum lock nosso (nem o herdado do --update) vaza para o
    # pinokiocontrol, para o vnccontrol nem para os ring-consumers eternos.
    # O ambiente repassa as rotas DESTA execução: em sandbox o reinício segue
    # hermético (lock, marker, lista e /opt daqui — nunca os reais).
    if env PINOKIOCONTROL_STATE_DIR="$STATE_DIR" \
            PINOKIOCONTROL_OPT_DIR="$APP_DIR" \
            PINOKIOCONTROL_SESSION_APPS_FILE="$SESSION_APPS_FILE" \
            "$PC_BIN_DIR/pinokiocontrol" --restart 9>&- 8>&-; then
        healed "Pinokio reiniciado na versão instalada ($(installed_version))."
        RESTART_STATUS="reiniciado"
    else
        RESTART_STATUS="falhou"
        if [ "$ACTION" = REPAIR ]; then
            # o build anterior é o que o próprio REPAIR declarou quebrado: não adianta voltar a ele
            RESTART_FAIL="o Pinokio não voltou após a troca de arquivos (o app não respondeu) — rode: pinokiocontrol --start e veja o log do app"
        else
            RESTART_FAIL="o Pinokio não voltou após a troca de arquivos (o app não respondeu) — rode: pinokiocontrol --start; se o build novo não subir, volte ao anterior com: PINOKIO_INSTALLER_VERSION=${CURRENT_VER:-<versão anterior>} + este instalador"
        fi
        warn "$RESTART_FAIL."
        return 1
    fi
    return 0
}
RESTART_STATUS="sem-troca"; RESTART_FAIL=""
restart_app_after_swap || true

persist_autostart() {
    local vncbin listed
    vncbin="$(vnccontrol_bin)"
    if [ -z "$vncbin" ]; then
        info "vnccontrol não encontrado — autostart de sessão é padrão do lab; nada a fazer aqui."
        PERSIST_STATUS="nao-aplicavel"
        return 0
    fi
    info "vnccontrol detectado: $vncbin"

    # v.261121d (R2/R3): um --persistent OFF deliberado (marker do
    # pinokiocontrol) NÃO é desfeito por rerun do instalador — sem isso,
    # manutenção rotineira com o one-liner religava o app no boot.
    if [ -f "$STATE_DIR/persistent" ] && grep -qx OFF "$STATE_DIR/persistent" 2>/dev/null; then
        info "persistent=OFF (decisão do operador via pinokiocontrol) — autostart NÃO registrado; app não voltará no boot."
        PERSIST_STATUS="respeitado-off"
        return 0
    fi

    info "session-apps em: $SESSION_APPS_FILE"

    # 1) Reconciliar a lista de session-apps (idempotente).
    if [ -f "$SESSION_APPS_FILE" ]; then
        # rc do grep neutralizado: arquivo existente porém vazio/só-comentários
        # e estado legítimo — sem o "|| true" o pipefail+set -e matariam o
        # instalador silenciosamente aqui (achado do revisor 1, round 1).
        listed="$( { grep -vE '^[[:space:]]*(#|$)' "$SESSION_APPS_FILE" 2>/dev/null || true; } | tr '\n' ' ')"
        case " $listed " in
            *" $SESSION_APP_ID "*)
                ok "session-app '$SESSION_APP_ID' já registrado em $SESSION_APPS_FILE"
                ;;
            *)
                # Garante newline ANTES do append (arquivo editado à mão sem
                # \n final colaria IDs na mesma linha e o vnccontrol os
                # ignoraria — achado do revisor 3, round 1).
                if [ -n "$(tail -c 1 "$SESSION_APPS_FILE" 2>/dev/null)" ]; then
                    printf '\n' >> "$SESSION_APPS_FILE" 2>/dev/null || true
                fi
                if printf '%s\n' "$SESSION_APP_ID" >> "$SESSION_APPS_FILE" 2>/dev/null; then
                    healed "session-app '$SESSION_APP_ID' acrescentado a $SESSION_APPS_FILE"
                else
                    warn "Falha ao acrescentar '$SESSION_APP_ID' em $SESSION_APPS_FILE (permissão?)."
                    PERSIST_STATUS="falhou"
                    return 1
                fi
                ;;
        esac
    else
        info "$SESSION_APPS_FILE ausente — vnccontrol usará a lista default (já inclui '$SESSION_APP_ID')."
    fi

    # 2) Subir AGORA se a área VNC estiver de pé (idempotente por marcador
    #    de processo; --no-sandbox é responsabilidade do vnccontrol).
    if vnc_area_up; then
        info "Área VNC ativa — iniciando session-apps (idempotente)..."
        # v.261121d (R1 crítico): 9>&- fecha o flock DESTE instalador; 8>&-
        # fecha fd herdado do pinokiocontrol (--update). Sem isso, os ring-
        # consumers eternos do vnccontrol herdavam o lock e o 2º run do
        # one-liner morria "Outra execução em andamento" NA FROTA INTEIRA.
        # v.261126b (R2): o app sobe dentro de um SCOPE próprio da system.slice
        # para NÃO ficar no cgroup de quem chamou o instalador (sessão SSH,
        # serviço de agente…) — com KillMode=control-group, derrubar a unidade
        # do chamador levava o Pinokio, o Caddy e o SearXNG junto. Sem
        # systemd-run (ou sem root): como antes.
        local -a autostart_cmd=(timeout 180 "$vncbin" --session-apps start)
        if systemd_scope_available; then
            autostart_cmd=(systemd-run --quiet --scope --unit="pinokio-autostart-$(date +%s)-$$" \
                           --slice=system.slice -- "${autostart_cmd[@]}")
        fi
        if "${autostart_cmd[@]}" 9>&- 8>&-; then
            PERSIST_STATUS="aplicada"
        else
            warn "'$vncbin --session-apps start' retornou erro."
            PERSIST_STATUS="falhou"
            return 1
        fi
    else
        info "Área VNC desligada — '$SESSION_APP_ID' subirá automaticamente na próxima sessão VNC."
        PERSIST_STATUS="registrada"
    fi
    return 0
}

if [ "$SKIP_AUTOSTART" = "1" ]; then
    info "Autostart pulado (PINOKIO_SKIP_AUTOSTART=1)."
else
    persist_autostart || true
fi

# ---------------------------------------------------------------------------
# AUTO-VERIFICAÇÃO (veredito) — inclui saúde, gate e persistência
# ---------------------------------------------------------------------------
FINAL_VER="$(installed_version)"
FAIL=""

if [ -n "$FINAL_VER" ] && dpkg --compare-versions "$FINAL_VER" ge "$CAND_VER" 2>/dev/null; then
    : # versão ok (>= melhor compatível)
else
    FAIL="pacote instalado (${FINAL_VER:-NENHUM} < $CAND_VER)"
fi
[ -x "$LAUNCHER" ]        || FAIL="${FAIL:+$FAIL; }launcher $LAUNCHER não executável"
[ -f "$DESKTOP_FILE" ]    || FAIL="${FAIL:+$FAIL; }desktop entry ausente"
icons_ok                  || FAIL="${FAIL:+$FAIL; }ícone hicolor ausente"
app_bin_ok                || FAIL="${FAIL:+$FAIL; }binário $APP_BIN ausente/não executável"
[ -f "$SANDBOX_BIN" ]     || FAIL="${FAIL:+$FAIL; }chrome-sandbox ausente"
[ "$(stat -c %a "$SANDBOX_BIN" 2>/dev/null || echo '')" = "$SANDBOX_WANT_PERM" ] \
                          || FAIL="${FAIL:+$FAIL; }permissão do chrome-sandbox divergente do postinst oficial"
installed_glibc_ok        || FAIL="${FAIL:+$FAIL; }pty.node incompatível com o GLIBC do host ($HOST_GLIBC)"
[ -x "$PC_BIN_DIR/pinokiocontrol" ] || FAIL="${FAIL:+$FAIL; }pinokiocontrol não instalado"
[ "$PERSIST_STATUS" != "falhou" ]  || FAIL="${FAIL:+$FAIL; }persistência/autostart falhou"
[ "$RESTART_STATUS" != "falhou" ]  || FAIL="${FAIL:+$FAIL; }$RESTART_FAIL"
[ "$SHA_UNVERIFIED" = 0 ]          || FAIL="${FAIL:+$FAIL; }sha256 do asset NÃO verificado (modo fallback sem API)"
grep -q "^VERSION=$CAND_VER$" "$STATE_FILE" 2>/dev/null \
                          || FAIL="${FAIL:+$FAIL; }state não registra a versão instalada"

SEARX_8888="$(searx_code)"
if [ "$SEARX_8888" != 200 ] && [ "$RESTART_STATUS" = "reiniciado" ]; then
    # v.261126a: o app ACABOU de subir e o Home Server (SearXNG) leva alguns
    # segundos — julgar a :8888 na hora era corrida (aviso falso). Espera até
    # PINOKIO_SEARX_WAIT s (default 90; cada tentativa tem 5 s de timeout).
    searx_deadline=$(( $(date +%s) + SEARX_WAIT ))
    while [ "$(date +%s)" -lt "$searx_deadline" ]; do
        sleep 3
        SEARX_8888="$(searx_code)"
        if [ "$SEARX_8888" = 200 ]; then break; fi
    done
fi
if [ "$RESTART_STATUS" = "reiniciado" ]; then
    # v.261126b (R2): "reiniciado" só vale se o app ainda estiver vivo AQUI —
    # o --start devolve 0 na primeira resposta 200 da porta, e um app que
    # morre em seguida passava sem aviso nenhum.
    managed_app_pids
    [ -n "$MANAGED_PIDS" ] || FAIL="${FAIL:+$FAIL; }o Pinokio MORREU logo após o reinício (nenhum processo do app) — rode: pinokiocontrol --start e veja o log do app"
    if [ "$SEARX_BEFORE" = 200 ] && [ "$SEARX_8888" != 200 ]; then
        FAIL="${FAIL:+$FAIL; }o SearXNG (:8888) estava no ar antes da troca e NÃO voltou depois do reinício"
    fi
fi
if [ "$SEARX_8888" = 200 ]; then
    info "SearXNG responde em :8888 (padrão da rede) — http 200"
else
    managed_app_pids
    if [ -n "$MANAGED_PIDS" ]; then
        warn "Pinokio ativo mas SearXNG não respondeu em :8888 (http $SEARX_8888) — app SearXNG parado dentro do Pinokio?"
    fi
fi

echo "--------------------------------------------------------------"
echo " Versão instalada : ${FINAL_VER:-NENHUM}  (latest oficial: $LATEST_VER; instalada foi escolhida pelo gate GLIBC)"
echo " Launcher         : $LAUNCHER"
echo " Controle local   : $PC_LINK (pinokiocontrol $SCRIPT_VERSION)"
echo " Desktop/Ícone    : $DESKTOP_FILE + hicolor/$ICON_NAME"
echo " Saúde            : $( [ -z "$HEALED_ITEMS" ] && echo 'nenhum reparo necessário' || echo "reparado: $HEALED_ITEMS" )"
echo " Persistência     : $PERSIST_STATUS (session-apps do vnccontrol: $SESSION_APPS_FILE)"
echo " Reinício         : $RESTART_STATUS (após UPGRADE/REPAIR/REINSTALL, se o app estava no ar)"
[ -n "$WARN_ITEMS" ] && echo " Avisos           : $WARN_ITEMS"
echo "--------------------------------------------------------------"
if [ -z "$FAIL" ]; then
    ok "VEREDITO: OK — Pinokio padronizado, saudável e $( [ "$ACTION" = "SKIP" ] && echo 'já na melhor versão compatível' || echo "${OP_LABEL} concluído" )."
else
    warn "VEREDITO: OK COM RESSALVAS — $FAIL"
    exit 1
fi
