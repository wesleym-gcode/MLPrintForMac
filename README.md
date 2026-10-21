# ML Print for Mac

Aplicativo nativo para macOS (SwiftUI) que imprime por **Wi-Fi** na
**Samsung ML-2160 / ML-2165W**, sem depender do driver da Samsung (que não
funciona em Macs recentes).

> Independente: não tem vínculo com Samsung nem HP.

## Recursos

- Descobre a impressora na rede (Bonjour) ou por IP; mostra estado e avisos.
- Imprime **PDF, imagens, Word (DOCX/DOC/ODT), RTF, TXT, HTML**.
- Pré-visualização folha a folha.
- Retrato/Paisagem, ajuste ou tamanho real, 1/2/4/6/9 páginas por folha, margem extra.
- Intervalo de páginas, cópias (agrupadas ou não), ordem inversa.
- **Frente e verso manual** (borda longa/curta) com pausa para virar as folhas.
- Densidade do toner, economia de toner, tipo de papel, alimentação manual.
- Modo **Fácil** e **Avançado**.
- Fila da impressora (cancelar trabalhos) e página de teste.
- Janela **Rede sem fio**: lê SSID, canal, IP e MAC por SNMP e abre o painel
  SyncThru da impressora para trocar de rede.
- "Abrir com…" no Finder e atalho no menu PDF do diálogo de impressão do macOS.

## Como funciona

A ML-2160 só entende o formato proprietário Samsung **QPDL/SPL**. O app:

1. renderiza cada folha a 600 dpi com PDFKit/CoreGraphics e converte para 1 bit;
2. passa o raster pelo filtro open source [splix](https://github.com/valdikss/splix)
   (embutido no app) para gerar QPDL;
3. envia o job por **IPP** (`ipp://IP/ipp/printer`).

Não usa fila CUPS nem exige `sudo`.

## Requisitos

macOS 13+ em Mac com Apple Silicon. Para compilar: Xcode Command Line Tools.

## Compilar

```bash
./scripts/build-splix.sh   # baixa e compila o filtro splix (GPL v2) em Resources/
./build.sh                 # gera build/ML Print for Mac.app
./make-pkg.sh              # gera build/ML-Print-for-Mac-1.0.pkg
```

Verificações sem abrir a janela:

```bash
"build/ML Print for Mac.app/Contents/MacOS/MLPrint" --selftest
"build/ML Print for Mac.app/Contents/MacOS/MLPrint" --render doc.pdf saida.png n=4 landscape
```

## Instalação e segurança do macOS

O app e o `.pkg` não são assinados por um Apple Developer ID. Na primeira vez,
clique com o botão direito ▸ **Abrir**. Aceite também a permissão de **Rede Local**.

Para assinar o instalador: `SIGN_ID="Developer ID Installer: ..." ./make-pkg.sh`.

## Licenças

Código do app: [MIT](LICENSE). O app embute componentes GPL v2 (splix e
JBIG-KIT); veja [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

---

Developed by Wesley Melo ([GreatCode.com.br](https://greatcode.com.br))
