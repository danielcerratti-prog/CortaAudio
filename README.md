# CortaÁudio 1.1

Editor simples para selecionar, pré-escutar, cortar e converter trechos de áudio usando o FFmpeg instalado no Windows. A interface roda no Microsoft Edge e o processamento é feito localmente.

## Recursos

- Seleção visual pela forma de onda, com início e fim ajustáveis por tempo.
- Pré-escuta do trecho selecionado.
- Corte e conversão com o FFmpeg instalado.
- Formatos de saída: MP3, WAV, M4A/AAC, OGG Vorbis e FLAC, conforme os codecs disponíveis no FFmpeg.
- Compatível com Windows 10/11 e Microsoft Edge.
- Não requer Python nem conexão com a internet durante o processamento.
- O serviço local escuta somente em `127.0.0.1`.

## Como usar

1. Baixe este repositório (botão **Code → Download ZIP**) e extraia os arquivos.
2. Dê dois cliques em `INICIAR_CortaAudio.bat`.
3. O navegador abrirá o editor. Mantenha a janela do PowerShell aberta enquanto estiver usando a ferramenta.
4. Escolha um áudio, ajuste o início e o fim, ouça a seleção e clique em **Cortar e baixar**.
5. Para encerrar, pressione `Ctrl+C` na janela do PowerShell ou feche-a.

## Requisito: FFmpeg

O FFmpeg precisa estar instalado no Windows. Para verificar, abra o Prompt de Comando e execute:

```bat
ffmpeg -version
```

Se não for encontrado automaticamente, edite `FFMPEG_PATH.txt` e acrescente o caminho completo para `ffmpeg.exe`, por exemplo:

```text
C:\ffmpeg\bin\ffmpeg.exe
```

Salve o arquivo e reinicie o inicializador. Os formatos de saída dependem dos codificadores incluídos na sua versão do FFmpeg.

## Arquivos

- `index.html`: interface visual.
- `CortaAudioServer.ps1`: servidor local em PowerShell e integração com FFmpeg.
- `INICIAR_CortaAudio.bat`: inicializador para Windows.
- `FFMPEG_PATH.txt`: configuração opcional para o caminho do FFmpeg.
- `LEIA-ME.txt`: instruções em português.
- `VERSION.txt`: versão do projeto.

## Privacidade

Os arquivos de áudio não são enviados para serviços externos. O navegador envia o arquivo ao serviço local do computador e o FFmpeg realiza o corte/conversão na máquina. Os arquivos temporários são removidos ao fim da operação.

## Limitações

- A pré-visualização depende dos codecs aceitos pelo Edge e pelo FFmpeg.
- Formatos e opções de qualidade dependem dos codecs disponíveis no executável FFmpeg instalado.
- O serviço local precisa permanecer aberto enquanto o editor estiver em uso.

**Versão 1.1** · Sem Python · FFmpeg local · Interface em português.
