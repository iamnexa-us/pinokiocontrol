# pinokiocontrol — instalador headless-first + CLI de controle para o Pinokio

[![version](https://img.shields.io/badge/version-261126d--pub1-766b90)](https://github.com/iamnexa-us/pinokiocontrol)
[![platform](https://img.shields.io/badge/platform-Linux-informational?logo=linux&logoColor=white)](https://github.com/iamnexa-us/pinokiocontrol)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![GitHub repo](https://img.shields.io/badge/github-pinokiocontrol-181717?logo=github&logoColor=white)](https://github.com/iamnexa-us/pinokiocontrol)

[English](README.md) | **Português**

O Pinokio é um app maravilhoso — no desktop. Em **servidores e máquinas
headless**, instalá-lo, mantê-lo atualizado e recuperá-lo quando uma atualização
dá errado é difícil: não há desktop pra clicar, um auto-updater que instala um
build quebrado derruba a máquina, e um crash numa distro madura (Debian, Ubuntu
LTS, Mint) deixa você com um serviço que morre no lançamento.

Essa dor a gente viveu — então construimos a cura. Uma linha instala o Pinokio
pela **fonte oficial**; depois disso, o `pinokiocontrol` o mantém saudável,
atualizado com segurança e **totalmente gerenciável pelo terminal**.

```bash
curl -fsSL https://raw.githubusercontent.com/iamnexa-us/pinokiocontrol/main/install.sh | sudo bash
```

## Por que você quer isso num servidor

- **Gate GLIBC** — antes de instalar qualquer release, o instalador abre o
  `.deb` e verifica os binários nativos contra o glibc do seu sistema. Uma
  release que morreria no lançamento é recusada, com fallback automático para a
  última versão boa. (Nasceu de um incidente real: a 8.4.0 upstream foi
  compilada numa imagem de CI rolante exigindo `GLIBC_2.42` e derrubou frotas
  inteiras em Debian 12/13 e Ubuntu LTS.) O cache do gate é atrelado à
  **identidade do asset** que ele avaliou (sha256): se o upstream substituir um
  `.deb` sob a mesma tag — como fez com a 8.4.1 em 25/11/2026 — o instalador o
  reavalia sozinho em vez de confiar num veredito vencido.
- **Reinício após a upgrade** — UPGRADE/REPAIR/REINSTALL trocam os arquivos em
  disco, então o instalador reinicia o app se ele estava no ar. Conte com
  cerca de um minuto sem a UI e sem o SearXNG. Só são tocados os processos
  cujo executável mora em `/opt/Pinokio`; o relançamento roda num scope
  próprio do systemd (nunca no cgroup de quem rodou o instalador); e o
  veredito confere se o app — e o SearXNG que estava no ar antes — voltaram
  mesmo. `PINOKIO_SKIP_AUTOSTART=1` pula o reinício (o build antigo continua
  rodando; o instalador avisa). Se o lançamento isolado não subir, ele tenta
  mais uma vez sem isolamento e avisa. E uma varredura de `/proc` que falha
  nunca é lida como "o app está parado": o instalador e o `pinokiocontrol`
  recusam (rc=1) em vez de agir no achismo.
- **Nunca rebaixa uma instalação sã** — quando a latest é recusada, o
  instalador só vai para uma known-good mais *nova* do que a instalada. Uma
  instalação sã acima da known-good fica onde está. (Até a v.261126a o
  one-liner a rebaixava em silêncio.) Um `PINOKIO_INSTALLER_VERSION` explícito
  continua podendo voltar atrás de propósito. Dano crítico de arquivos nessa
  instalação continua sendo reparado (REINSTALL da mesma versão), e o
  `pinokiocontrol --update` percebe quando o binário do app sumiu.
- **`PINOKIO_INSTALLER_KNOWN_GOODS` é validado antes de tudo** — a lista é
  injetada no `pinokiocontrol` gerado, então qualquer coisa além de versões
  separadas por espaço (aspas, quebras de linha, sintaxe de shell) para o
  instalador antes de ele tocar na máquina.
- **Auto-updater neutralizado por padrão** — atualizações só acontecem quando
  VOCÊ roda, através do gate. Chega de autodestruição silenciosa às 3 da manhã.
- **Health checks com auto-reparo** — binário, desktop entry, ícones,
  permissões, launcher: qualquer coisa quebrada é detectada e reparada na
  próxima execução. Vereditos sempre honestos (`OK`, `OK com ressalvas`, ou
  falha clara — nunca um sucesso silencioso).
- **Idempotente sob tortura** — rode 10× só pra ver se quebra: nada baixa de
  novo (no máximo uma vez a cada 24 h quando a API do GitHub não informa o
  digest do asset), nada quebra. Lock de instância única previne execuções
  concorrentes.
- **Controle total pelo terminal** — desktop nunca mais necessário.

## pinokiocontrol

```
pinokiocontrol --status               # versões (local + upstream), ativo?,
                                      # porta, compatibilidade GLIBC, persistência
pinokiocontrol --update               # atualiza script e/ou Pinokio (com gate)
pinokiocontrol --start | --stop | --restart
pinokiocontrol --persistent ON|OFF    # se volta (ou não) no próximo boot
pinokiocontrol --help | --version
```

O `--stop` escala com elegância (TERM → até 10 s → KILL) e espera a morte real
antes de retornar. O `--persistent` gerencia só o próprio registro e nunca
toca em outros apps de sessão. O `--status` não precisa de root; sem root ele
responde `ativo: n/d` em vez de um "não está ativo" errado (não dá para ler
`/proc/<pid>/exe` de processos de outros usuários). `--start`, `--stop` e
`--restart` recusam (rc=1) quando a varredura de `/proc` falha, em vez de
agir no achismo.

## O que o instalador decide (tudo honesto, tudo logado)

| Estado da máquina | Ação |
|---|---|
| Sem Pinokio | **INSTALL** do melhor candidato compatível |
| Antigo, latest compatível | **UPGRADE** (dados do usuário preservados; reinicia se estava no ar) |
| Já na melhor e saudável | **SKIP** — audita, não baixa nada |
| Dano crítico de arquivos | **REINSTALL** da mesma versão (reinicia se estava no ar) |
| Binário instalado incompatível (GLIBC) | **REPAIR** — downgrade automático p/ known-good |
| Latest incompatível | **PINNED** — mantém a versão compatível mais nova (nunca um downgrade silencioso), nota explícita |
| Todos os candidatos reprovados, instalação são | **ADOPTION** — mantém a atual, protege |

## Variáveis (sandbox/testes)

`PINOKIO_INSTALLER_ROOT` (realoca TODOS os caminhos de sistema),
`PINOKIO_INSTALLER_REPO`, `PINOKIO_INSTALLER_STATE_DIR`,
`PINOKIO_INSTALLER_DL_DIR`, `PINOKIO_INSTALLER_VERSION` (pin exato),
`PINOKIO_INSTALLER_KNOWN_GOODS`, `PINOKIO_ALLOW_AUTOUPDATE`,
`PINOKIO_SKIP_AUTOSTART`, `PINOKIOCONTROL_BIN_DIR`, `PINOKIOCONTROL_LINK_DIR`,
`PINOKIO_GATE_CACHE_TTL`, `PINOKIO_SEARX_WAIT`, `GITHUB_TOKEN`.

## Licença

**MIT** — Autor: **Louise** em parceria com **Marco**.
Os scripts são MIT; o Pinokio e seus binários pertencem aos seus respectivos
autores ([pinokiocomputer/pinokio](https://github.com/pinokiocomputer/pinokio)).

Issues e PRs são bem-vindos! 💙

---

Nosso conteúdo é feito por uma família com muito amor, pessoas como você.
Prestigie https://iamnexa.us/
