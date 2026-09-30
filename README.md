# Ollama iGPU Performance Tuning

Begleitmaterial zur Präsentation [`Ollama_iGPU_Performance_Tuning.pptx`](Ollama_iGPU_Performance_Tuning.pptx)
(auch als [PDF](Ollama_iGPU_Performance_Tuning.pdf)).

Das Projekt zeigt, wie sich ein lokaler, deutschsprachiger KI-Assistent vollständig auf
eigener Hardware betreiben lässt – ohne Cloud-LLM und mit Beschleunigung über eine
AMD-iGPU. Drei Docker-Komponenten arbeiten dabei zusammen:

| Komponente | Aufgabe | Port |
|------------|---------|------|
| **Ollama** | Führt die Sprach- und Embedding-Modelle lokal auf der iGPU aus (Vulkan, Flash Attention, quantisierter KV-Cache) | `11434` |
| **Qdrant** | Vektordatenbank als Wissensspeicher (RAG) für Dokumente und gespeicherte Texte | `6333`, `6334` |
| **n8n** | Orchestriert den KI-Agenten, die Tools und die Dokumentverarbeitung über Workflows | `5678` |

## Inhalt

- [`docker-compose.yml`](docker-compose.yml): Container für Ollama, Qdrant und n8n (plus einen optionalen `orientation`-Dienst)
- [`Modelfile`](Modelfile): angepasstes Ollama-Modell auf Basis von `cyberwald/sauerkrautlm-nemo-12b-instruct` mit deutschem System-Prompt, Sampler- und Hardwareparametern
- [`n8n_Workflows/`](n8n_Workflows): n8n-Workflows des KI-Assistenten
  - `Memory-Agent.json`: Haupt-Workflow mit AI Agent, Chat-Webhook und Dokumentimport
  - `Tool - Qdrant Speichern.json`: speichert Texte in der Wissensdatenbank
  - `Tool - Qdrant Suche.json`: semantische Suche in der Wissensdatenbank
  - `Tool - Seite lesen.json`: liest den Textinhalt einer Webseite
- [`ollama-kv-info.sh`](ollama-kv-info.sh): interaktives Skript zur Anzeige von Modell- und KV-Cache-Informationen
- [`tool_call.py`](tool_call.py): minimales Python-Beispiel für Tool-Calling direkt gegen die Ollama-API
- [`example-deutsch.txt`](example-deutsch.txt), [`example-englisch.txt`](example-englisch.txt), [`filler_german.txt`](filler_german.txt), [`filler_english.txt`](filler_english.txt): Beispieltexte für lokale Tests

## Das Projekt: lokaler KI-Assistent mit Gedächtnis

Der Workflow **Memory-Agent** stellt einen n8n-AI-Agenten bereit, der über Ollama mit
`qwen2.5:14b-instruct` antwortet und sich über ein Kurzzeitgedächtnis (Simple Memory, pro
`sessionId`) den Gesprächsverlauf merkt. Er besteht aus zwei Teilen:

### 1. Chat (`POST /webhook/chat`)

Nachrichten werden per Webhook entgegengenommen und als Stream beantwortet. Der Agent ruft
Tools **nur** auf, wenn die Nachricht mit einem Schlüsselwort beginnt:

| Präfix | Tool | Funktion |
|--------|------|----------|
| `QR: <Frage>` | `qr` → *Tool - Qdrant Suche* | Semantische Suche in der Wissensdatenbank |
| `QS: <Text>` | `qs` → *Tool - Qdrant Speichern* | Text dauerhaft in der Wissensdatenbank speichern |
| `WS: <Frage>` | `ws` → Search1API | Websuche nach aktuellen Informationen |
| `WQ: <URL> <Frage>` | `wq` → *Tool - Seite lesen* | Inhalt einer Webseite über `r.jina.ai` lesen |

Ohne Präfix antwortet das Modell aus eigenem Wissen. Diese explizite Steuerung verhindert
unnötige Tool-Aufrufe und hält die Antwortzeiten auf der iGPU kurz.

### 2. Dokumentimport (`GET /webhook/read-files`)

1. Die Qdrant-Collection `nexamind_knowledge` wird gelöscht und neu angelegt (768 Dimensionen, Cosine).
2. Alle PDFs aus `/home/node/.n8n-files/` (Host: `./n8n_files/`) werden eingelesen.
3. Der Text wird in Chunks à 1000 Zeichen mit 200 Zeichen Überlappung zerlegt.
4. Jeder Chunk wird mit `nomic-embed-text` eingebettet und mit Dateiname und Titel in Qdrant gespeichert.

Anschließend kann der Inhalt der Dokumente über `QR:` abgefragt werden.

## Frontend: n8n-Client

Als Benutzeroberfläche kann der **n8n AI-Textassistent** verwendet werden – ein
React/TypeScript-Client (Vite), der die Webhooks `chat` und `read-files` dieses Workflows
anspricht:

➡️ **https://github.com/Ralfhgw/project_n8n_AI-Textassistent**

Der Client wird über eine `.env`-Datei auf die n8n-Instanz konfiguriert
(`VITE_N8N_HOST`, `VITE_N8N_PORT`, `VITE_OPERATION_MODE`). Im Modus `development` nutzt er
die Test-Webhooks (`/webhook-test/...`), im Modus `production` die produktiven Webhooks
des aktivierten Workflows (`/webhook/...`). Details stehen im README des Client-Repositories.

## Installation der Docker-Komponenten

### Voraussetzungen

- Linux (oder WSL2) mit Docker Engine und Docker Compose Plugin
- Eine unterstützte AMD-iGPU sowie Zugriff auf `/dev/dri` und `/dev/kfd`
- Ausreichend RAM für das gewählte Modell (die iGPU nutzt den Arbeitsspeicher gemeinsam mit der CPU)

### 1. Repository klonen

```bash
git clone <repo-url> igpu-performance-tuning
cd igpu-performance-tuning
mkdir -p n8n_files
```

PDFs, die in die Wissensdatenbank übernommen werden sollen, werden nach `n8n_files/` kopiert.

### 2. `docker-compose.yml` an das Hostsystem anpassen

Einige Werte sind systemabhängig und müssen vor dem ersten Start geprüft werden:

- **GPU-Gruppen** (`group_add` bei `ollama`): Die IDs müssen zu den Gruppen `video` und
  `render` des Hosts passen:

  ```bash
  getent group video render
  ```

- **`WEBHOOK_URL`** (bei `n8n`): auf die IP bzw. den Hostnamen setzen, unter dem n8n im
  Netzwerk erreichbar ist (aktuell `http://192.168.2.31:5678/`).
- **`N8N_RESTRICT_FILE_ACCESS_TO`**: enthält neben `/home/node/.n8n-files` einen
  hostspezifischen Pfad, der bei Bedarf angepasst werden kann.
- **Ollama-Umgebungsvariablen**: Das iGPU-Tuning erfolgt über `OLLAMA_VULKAN=1`,
  `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_KV_CACHE_TYPE=q4_0`, `OLLAMA_NUM_PARALLEL=1`,
  `OLLAMA_MAX_LOADED_MODELS=1` und `OLLAMA_KEEP_ALIVE=-1`. Für manche GPUs kann
  `HSA_OVERRIDE_GFX_VERSION` (auskommentiert) notwendig sein.

> **Hinweis:** Der n8n-Container läuft `privileged` und hat Zugriff auf den Docker-Socket
> des Hosts. Das ist für eine lokale Test-/Schulungsumgebung gedacht und sollte nicht
> ungeprüft in produktive oder öffentlich erreichbare Umgebungen übernommen werden.

### 3. Container starten

```bash
docker compose up -d ollama qdrant n8n
```

Der `orientation`-Dienst ist optional. Sein Compose-Eintrag verwendet `build: .`, im
Repository ist dafür derzeit kein Dockerfile enthalten.

Prüfen, ob alle Dienste laufen:

```bash
docker compose ps
curl http://localhost:11434/api/tags      # Ollama
curl http://localhost:6333/collections    # Qdrant
# n8n: http://localhost:5678 im Browser öffnen
```

Die Daten werden in den lokalen Verzeichnissen `ollama_data`, `qdrant_data`, `n8n_data`
und `n8n_files` gespeichert.

### 4. Ollama-Modelle laden

Benötigt werden ein Chat-Modell und das Embedding-Modell:

```bash
docker exec -it ollama_container ollama pull qwen2.5:14b-instruct
docker exec -it ollama_container ollama pull nomic-embed-text
```

Optional kann das angepasste Modell aus dem [`Modelfile`](Modelfile) erstellt werden:

```bash
docker exec -it ollama_container ollama pull cyberwald/sauerkrautlm-nemo-12b-instruct:latest
docker cp Modelfile ollama_container:/tmp/Modelfile
docker exec -it ollama_container ollama create igpu-tuned -f /tmp/Modelfile
docker exec -it ollama_container ollama list
```

Um es im Agenten zu verwenden, wird im Node **Ollama Chat Model** das Modell auf
`igpu-tuned` umgestellt.

Ob das Modell tatsächlich auf der GPU läuft, zeigt:

```bash
docker exec -it ollama_container ollama ps
```

### 5. n8n einrichten

1. n8n unter `http://localhost:5678` öffnen und einen Owner-Account anlegen.
2. Unter **Settings → Community Nodes** die Pakete `n8n-nodes-qdrant` und
   `n8n-nodes-search1api` installieren.
3. Credentials anlegen:
   - **Ollama**: Base URL `http://ollama:11434`
   - **Qdrant REST API**: URL `http://qdrant:6333`
   - **Search1API**: API-Key (nur für die Websuche `WS:` erforderlich)
4. Zuerst die drei Tool-Workflows aus [`n8n_Workflows/`](n8n_Workflows) importieren,
   danach `Memory-Agent.json`.
5. Im Memory-Agent in den Tool-Nodes `qr`, `qs` und `wq` die jeweiligen importierten
   Tool-Workflows auswählen (die Workflow-IDs ändern sich beim Import) und in allen
   Qdrant-, Ollama- und Search1API-Nodes die angelegten Credentials zuweisen.
6. Den Workflow **Memory-Agent** aktivieren, damit die produktiven Webhooks
   `/webhook/chat` und `/webhook/read-files` erreichbar sind.

Die Workflows sprechen Ollama und Qdrant über die Compose-Servicenamen `ollama` und
`qdrant` an. Diese Namen funktionieren nur innerhalb des Docker-Netzwerks, nicht vom Host.

### 6. Testen

```bash
# Dokumente aus n8n_files/ in Qdrant importieren
curl http://localhost:5678/webhook/read-files

# Chat-Anfrage stellen
curl -X POST http://localhost:5678/webhook/chat \
  -H "Content-Type: application/json" \
  -d '{"sessionId": "test", "chatInput": "QR: Welche Dokumente sind gespeichert?"}'
```

Komfortabler geht es mit dem oben beschriebenen [Frontend](#frontend-n8n-client).

## Werkzeuge

### KV-Cache- und Modellinformationen

Das Skript [`ollama-kv-info.sh`](ollama-kv-info.sh) fragt installierte Modelle und
verfügbare Kontextgrößen ab und hilft beim Vergleich verschiedener Speicher- und
Kontextkonfigurationen. Es benötigt `docker`, `curl`, `jq` und `awk` auf dem Host:

```bash
chmod +x ollama-kv-info.sh
./ollama-kv-info.sh
```

### Tool-Calling ohne n8n

[`tool_call.py`](tool_call.py) zeigt das Tool-Calling-Prinzip direkt gegen die Ollama-API
(Modell `qwen3:8b`, Tool `Seite_lesen`):

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install requests
python tool_call.py
deactivate
```

## Aufräumen

Container stoppen:

```bash
docker compose down
```

Modelle, Vektordaten und n8n-Konfiguration bleiben in `ollama_data`, `qdrant_data` und
`n8n_data` erhalten. Für einen vollständigen Neustart müssen diese Verzeichnisse bewusst
separat entfernt werden.
