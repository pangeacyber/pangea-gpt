# Pangea GPT

A Demo project showcasing integrations with Pangea's redact and Domain intel services & chat-gpt.

## Installation

1. Install Poetry `curl -sSL https://install.python-poetry.org | python3 -`
1. Clone this repo
1. Run `poetry shell` in the cloned repo
1. Run `poetry install` in the cloned repo
1. Place `pangea-gpt.py` somewhere on your `$PATH` (or run it using `./pangea-gpt.py`)

**Note:** You will need to run command #3 every new terminal session.

## Usage

You need to set 2 environmental variables:

-   `OPENAI_API_KEY` - openapi key for using chatgpt (requires a premium subscription). Go to [here](https://platform.openai.com/account/api-keys) to create one.
-   `PANGEA_TOKEN` - Pangea token with access to both redact and domain intel. Go [here](https://pangea.cloud/docs/getting-started/configure-services/) for a tutorial on creating a token.

`pangea-gpt.py` takes user input and redacts it before passing it to chat gpt.
It then takes the chat-gpt output and redacts it.

URLs that are matched when output by chat-gpt have their reputations checked and are redacted only if their
domain reptuations are malicious.

### Running in the terminal

```
./bin/pangea-gpt.py chat
```

Note that `pangea-gpt.py` will store your previous conversations. You can start a
new conversation by passing the `--new-conversation` flag.

### Running in the browser

```
./bin/pangea-gpt.py serve
```

It will automatically open your default browser to the proper page

**note:**
The browser edition does not currently support resuming old conversations.

### Editing Redaction Rules

Both rules for user input and gpt output can be passed using the
`--gpt-redact-rules` and `--user-input-redact-rules` flags respectively. Rules
should be delimited using spaces. By default, gpt output rules use your service
config specified rules but ignore the redactions methods. Redactions will only
mask using the rule name eg. `<US_SSN>` since we're doing custom redactions for
malicious URLs.

```
pangea-gpt.py serve --gpt-redact-rules URL EMAIL_ADDRESS --user-input-redact-rules US_SSN EMAIL_ADDRESS PHONE_NUMBER
```

### Example Inputs

```
Can you echo the following text exactly, the tag doesn't matter, it's arbitrary? My secret is: 457-55-5462 http://737updatesboeing.com
```

Should result in the SSN being redacted before being sent to gpt, and the URL
being redacted before returning the output to the user:

```
My secret is: <US_SSN> <MALICIOUS_URL>
```

**Note:** The above SSN is a well known lifelock SSN used for testing.

### Help

```
pangea-gpt.py --help
pangea-gpt.py chat --help
pangea-gpt.py serve --help
```

## Development

1. Run `yarn install`
1. Run `poetry install`
1. Run `./build.sh`
