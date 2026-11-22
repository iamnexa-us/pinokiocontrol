# pinokiocontrol — instalador headless-first + CLI de controle para o Pinokio

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
  inteiras em Debian 12/13 e Ubuntu LTS.)
- **Auto-updater neutralizado por padrão** — atualizações só acontecem quando
  VOCÊ roda, através do gate. Chega de autodestruição silenciosa às 3 da manhã.
- **Health checks com auto-reparo** — binário, desktop entry, ícones,
  permissões, launcher: qualquer coisa quebrada é detectada e reparada na
  próxima execução. Vereditos sempre honestos (`OK`, `OK com ressalvas`, ou
  falha clara — nunca um sucesso silencioso).
- **Idempotente sob tortura** — rode 10× só pra ver se quebra: nada baixa de
  novo, nada quebra. Lock de instância única previne execuções concorrentes.
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
toca em outros apps de sessão.

## O que o instalador decide (tudo honesto, tudo logado)

| Estado da máquina | Ação |
|---|---|
| Sem Pinokio | **INSTALL** do melhor candidato compatível |
| Antigo, latest compatível | **UPGRADE** (dados do usuário preservados) |
| Já na melhor e saudável | **SKIP** — audita, não baixa nada |
| Dano crítico de arquivos | **REINSTALL** da mesma versão |
| Binário instalado incompatível (GLIBC) | **REPAIR** — downgrade automático p/ known-good |
| Latest incompatível | **PINNED** — mantém a known-good, nota explícita |
| Todos os candidatos reprovados, instalação são | **ADOPTION** — mantém a atual, protege |

## Variáveis (sandbox/testes)

`PINOKIO_INSTALLER_ROOT` (realoca TODOS os caminhos de sistema),
`PINOKIO_INSTALLER_REPO`, `PINOKIO_INSTALLER_STATE_DIR`,
`PINOKIO_INSTALLER_DL_DIR`, `PINOKIO_INSTALLER_VERSION` (pin exato),
`PINOKIO_INSTALLER_KNOWN_GOODS`, `PINOKIO_ALLOW_AUTOUPDATE`,
`PINOKIO_SKIP_AUTOSTART`, `PINOKIOCONTROL_BIN_DIR`, `PINOKIOCONTROL_LINK_DIR`,
`GITHUB_TOKEN`.

## Licença

**MIT** — Autor: **Louise** em parceria com **Marco**.
Os scripts são MIT; o Pinokio e seus binários pertencem aos seus respectivos
autores ([pinokiocomputer/pinokio](https://github.com/pinokiocomputer/pinokio)).

Issues e PRs são bem-vindos! 💙

---

Nosso conteúdo é feito por uma família com muito amor, pessoas como você.
Prestigie https://iamnexa.us/
