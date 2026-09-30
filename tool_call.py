import requests
# Aktivierung der virtuellen Umgebung für Python
# python3 -m venv .venv
# source .venv/bin/activate
# pip install requests
# python tool_call.py
# deactivate

OLLAMA_URL = "http://localhost:11434/api/chat"
MODEL = "qwen3:8b"

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "Seite_lesen",
            "description": "Liest den Textinhalt einer konkreten Webseite.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {
                        "type": "string",
                        "description": "Die vollständige URL, inklusive https://",
                    }
                },
                "required": ["url"],
            },
        },
    }
]

def call_seite_lesen(url: str) -> str:
    resp = requests.get(f"https://r.jina.ai/{url}", timeout=30)
    resp.raise_for_status()
    return resp.text[:4000] 

def chat(messages, use_tools: bool = True) -> dict:
    payload = {"model": MODEL, "messages": messages, "stream": False}
    if use_tools:
        payload["tools"] = TOOLS
    resp = requests.post(OLLAMA_URL, json=payload, timeout=300)
    resp.raise_for_status()
    return resp.json()["message"]

def main():
    messages = [
        {"role": "user", "content": "Lies https://www.anthropic.com und sag mir was drauf steht."}
    ]

    assistant_msg = chat(messages)
    messages.append(assistant_msg)

    if assistant_msg.get("tool_calls"):
        for call in assistant_msg["tool_calls"]:
            name = call["function"]["name"]
            args = call["function"]["arguments"]

            if name == "Seite_lesen":
                result = call_seite_lesen(args["url"])
            else:
                result = f"Unbekanntes Tool angefordert: {name}"

            messages.append({"role": "tool", "content": result})

        final_msg = chat(messages, use_tools=False)
        print(final_msg["content"])
    else:
        print(assistant_msg["content"])


if __name__ == "__main__":
    main()