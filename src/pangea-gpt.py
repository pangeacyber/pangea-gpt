#! /usr/bin/env python

import typing as t
import json
import sys
import signal
import pathlib
import threading
import os
import openai
import urllib.parse
import webbrowser
import argparse
from flask import Flask, request

from pangea import PangeaConfig
from pangea.services import Redact, DomainIntel


class ChatMessage(t.TypedDict):
    role: str
    content: str

Messages = t.List[t.Tuple[ChatMessage, str]]
PreviousMessages = Messages

FROM_USER_PROMPT = "\n<============================== From User\n\n"
CLASSIFIED_PROMPT = "\n-------- Redacted Data ----------\n"


if api_key := os.environ.get("OPENAI_API_KEY"):
    openai.api_key = api_key
else:
    raise ValueError("'OPENAI_API_KEY' is a required env var")

pangea_domain = os.environ.get("PANGEA_DOMAIN", "aws.us.pangea.cloud")
if (pangea_token := os.environ.get("PANGEA_TOKEN")) is None:
    raise ValueError("'PANGEA_TOKEN' is a required env var")

config = PangeaConfig(domain=pangea_domain)
redact_api = Redact(pangea_token, config)
domain_intel_api = DomainIntel(pangea_token, config)


app = Flask(__name__)


@app.route("/")
def home():
    return embedded_template


@app.route("/chat", methods=["POST"])
def chat():
    result = request.json
    assert result
    previous = result["previous"]
    user_message = result["message"]

    user_call = redact_api.redact(user_message, rules=args.user_input_redact_rules, debug=True)
    raw_redact_user_text = json.dumps(user_call.raw_response.json(), indent=2)
    user_redacted = user_call.result.redacted_text # type: ignore
    (gpt_message, redacted, raw_redact_gpt_text) = send_chatgpt_message(user_redacted, previous, args.gpt_redact_rules)
    previous.append(({"role": "user", "content": user_redacted}, user_redacted))
    previous.append((gpt_message, redacted))
    return {"previous": previous,
            "chat_gpt_message": gpt_message,
            "chat_gpt_redacted": redacted,
            "user_redacted": user_redacted,
            "raw_redact_user_text": raw_redact_user_text,
            "raw_redact_gpt_text": raw_redact_gpt_text,
            }


def run_flask(args):
    if args.bind.startswith("https://"):
        raise ValueError("pangea-gpt.py does not support https.")

    if args.bind.startswith("http://"):
        bind_address = args.bind
    else:
        bind_address = f"http://{args.bind}"

    bind = urllib.parse.urlparse(bind_address)
    flask_job = threading.Thread(target=app.run, kwargs={"host": bind.hostname, "port": bind.port})
    flask_job.start()
    webbrowser.open(bind_address, new=2)
    flask_job.join()


def run_chat(args):
    if args.new_conversation:
        previous = []
    else:
        previous = get_previous_text(args.previous_conversation)

    edited = False
    def term_handler(signum, frame):
        if edited:
            path = args.previous_conversation or pathlib.Path("/tmp/pangea_gpt_previous.json")
            print(f"\nSaving conversation to {path}...\n")
            with path.open("w") as f:
                json.dump(previous, f)
        sys.exit(0)

    signal.signal(signal.SIGINT, term_handler)
    signal.signal(signal.SIGTERM, term_handler)
    print_messages(previous)

    while True:
        user_content = input(FROM_USER_PROMPT)
        while not user_content.strip():
            user_content = input("")

        classified = redact_api.redact(user_content, rules=args.user_input_redact_rules).result.redacted_text # type: ignore
        print(CLASSIFIED_PROMPT)
        print(classified)

        gpt_message, redacted, _ = send_chatgpt_message(classified, previous, args.gpt_redact_rules)
        print_from_gpt(gpt_message["content"], redacted)

        edited = True
        previous.append(({"role": "user", "content": classified}, classified))
        previous.append((gpt_message, redacted))


def print_messages(messages: Messages):
    for (message, redaction) in messages:
        role = message["role"]
        content = message["content"]
        if role == "user":
            print_from_user(content, redaction)
        elif role == "assistant":
            print_from_gpt(content, redaction)


def print_from_gpt(message: str, redacted: str):
    print("\nFrom Chat-GPT 3.5 ==============================>\n")
    print(message)
    print("\n---------- Redacted Text ----------\n")
    print(redacted)


def print_from_user(message: str, classified_data: str):
    print(FROM_USER_PROMPT)
    print(message)
    print(CLASSIFIED_PROMPT)
    print(classified_data)


def get_previous_text(file: t.Optional[pathlib.Path]) -> PreviousMessages:
    if file is not None:
        if not file.exists():
            raise ValueError(f"File {args.previous_conversation} does not exist")
        with file.open("r") as f:
            return json.load(f)
    else:
        default_file = pathlib.Path("/tmp/pangea_gpt_previous.json")
        if default_file.exists():
            with default_file.open("r") as f:
                return json.load(f)
    return []


def send_chatgpt_message(message: str, previous_messages: PreviousMessages, redact_rules: t.List[str]) -> t.Tuple[ChatMessage, str, str]:
    result = openai.ChatCompletion.create(messages=[x[0] for x in previous_messages]+[{"role": "user", "content": message}], model="gpt-3.5-turbo")
    chat_message: ChatMessage = result["choices"][0]["message"] # type: ignore
    content = chat_message["content"]
    redact_response = redact_api.redact(text=content, rules=redact_rules, debug=True)
    payload = redact_response.raw_response.json() # type: ignore
    payload.pop("summary")
    payload["result"].pop("redacted_text")
    raw_redact_response = json.dumps(payload, indent=2)
    redacted_result = redact_response.result # type: ignore

    assert redacted_result
    report = redacted_result.report
    assert report

    redacted_text = content
    for result in report.recognizer_results:
        if result.redacted:
            if result.field_type == "URL":
                url = content[result.start:result.end]
                if url.startswith("http://"):
                    url = url[7:]
                elif url.startswith("https://"):
                    url = url[8:]
                if domain_intel_api.reputation(domain=url, provider="crowdstrike").result.data.verdict == "malicious": # type: ignore
                    init = redacted_text[:result.start]
                    tail = redacted_text[result.end:]
                    redacted_text = init + "<MALICIOUS_URL>" + tail
            else:
                redacted_text = replace_word(redacted_text, f"<{result.field_type}>", result.start, result.end)

    return ({"content": content, "role": "assistant"}, redacted_text, raw_redact_response)


def replace_word(text: str, replacement: str, start: int, end: int) -> str:
    init = text[:start]
    tail = text[end:]
    return init + replacement + tail


"""Replaced by envsubst"""
embedded_template = r"""
$EMBEDDED_TEMPLATE
"""


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    sub_parsers = parser.add_argument("--previous-conversation", type=pathlib.Path, help="File with a previous conversation allowing you to continue an existing conversation")
    sub_parsers = parser.add_subparsers(required=True, help="Sub command help")

    # Flask
    flask_parser = sub_parsers.add_parser("serve", help="Serve as an HTTP Page")
    flask_parser.set_defaults(func=run_flask)
    flask_parser.add_argument("--bind", help="The socket to bind", default="http://127.0.0.1:8000")
    flask_parser.add_argument("--gpt-redact-rules", nargs="+", default=[])
    flask_parser.add_argument("--user-input-redact-rules", nargs="+", default=["US_SSN", "IP_ADDRESS", "EMAIL_ADDRESS", "PHONE_NUMBER"])

    # Cmdline
    cmd_parser = sub_parsers.add_parser("chat", help="Chat within the terminal loading up an optional file")
    cmd_parser.set_defaults(func=run_chat)
    cmd_parser.add_argument("--gpt-redact-rules", nargs="+", default=[])
    cmd_parser.add_argument("--user-input-redact-rules", nargs="+", default=["US_SSN", "IP_ADDRESS", "EMAIL_ADDRESS", "PHONE_NUMBER"])
    cmd_parser.add_argument("--new-conversation", action="store_true", help="Clear the previous conversation and start a new one")

    args = parser.parse_args()

    args.func(args)
