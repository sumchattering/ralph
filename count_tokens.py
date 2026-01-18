#!/usr/bin/env python3
"""
Token counter using tiktoken for accurate GPT token counting.
Supports GPT-4/GPT-4o/o1 models which use cl100k_base encoding.
"""

import sys

def count_tokens(text: str, encoding_name: str = "cl100k_base") -> int:
    """
    Count the number of tokens in a text string.

    Args:
        text: The text to count tokens for
        encoding_name: The tiktoken encoding to use (default: cl100k_base for GPT-4/GPT-4o/o1)

    Returns:
        Number of tokens
    """
    import tiktoken
    encoding = tiktoken.get_encoding(encoding_name)
    return len(encoding.encode(text))


def main():
    # Read from stdin
    text = sys.stdin.read()

    # Count tokens using cl100k_base (GPT-4/GPT-4o/o1 encoding)
    token_count = count_tokens(text)

    # Print just the number
    print(token_count)


if __name__ == "__main__":
    main()
