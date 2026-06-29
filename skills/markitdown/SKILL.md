---
name: markitdown
description: 'Converts files to Markdown using Microsoft MarkItDown. Use when asked to convert PDF, DOCX, XLSX, PPTX, HTML, images, audio, CSV, JSON, XML, or ZIP files to Markdown. Supports "convert to markdown", "extract text", "markitdown", or "read this document".'
---

# MarkItDown — File-to-Markdown Converter

Converts documents, spreadsheets, presentations, PDFs, images, and more into clean Markdown using Microsoft's [markitdown](https://github.com/microsoft/markitdown) library.

## Prerequisites

The skill includes a Python venv with markitdown pre-installed. If the venv doesn't exist yet, create it:

```powershell
cd <skill-root>/scripts
python -m venv venv
venv\Scripts\pip install -r requirements.txt
```

## Usage

Run the bundled script to convert any supported file:

```powershell
cd <skill-root>/scripts
venv\Scripts\python convert.py "<path-to-file>"
```

The Markdown output is printed to stdout. Redirect to a file with `> output.md` if needed.

## Supported Formats

PDF, DOCX, XLSX, PPTX, HTML, CSV, JSON, XML, images (JPG/PNG with EXIF), audio (transcription), ZIP archives, YouTube URLs, EPUB.
