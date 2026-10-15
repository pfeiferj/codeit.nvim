"""Restricted YAML-to-JSON fallback for tool arguments; input is never executed."""
import json
import math
import re
import sys

import yaml
from yaml.events import AliasEvent
from yaml.nodes import MappingNode, ScalarNode, SequenceNode


NUMBER = re.compile(r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\Z")
MAX_BYTES = 1024 * 1024


def decode(text):
    # Reject YAML indirection and explicit types before composing even a base tree.
    count = 0
    for event in yaml.parse(text, Loader=yaml.BaseLoader):
        count += 1
        if count > 20000 or isinstance(event, AliasEvent):
            raise ValueError("YAML aliases or excessive input")
        if getattr(event, "anchor", None) or getattr(event, "tag", None):
            raise ValueError("YAML anchors and tags are not supported")

    def convert(node, depth=0):
        if depth > 64:
            raise ValueError("YAML nesting limit exceeded")
        if isinstance(node, ScalarNode):
            if node.style is not None:
                return node.value
            value = node.value
            if value == "" or value.lower() in (".inf", "+.inf", "-.inf", ".nan"):
                raise ValueError("Missing or non-finite YAML value")
            if value in ("true", "false", "null") or NUMBER.fullmatch(value):
                result = json.loads(value)
                if isinstance(result, float) and not math.isfinite(result):
                    raise ValueError("Non-finite number")
                return result
            # No YAML 1.1 booleans, dates, octal numbers, or implicit type coercion.
            return value
        if isinstance(node, SequenceNode):
            return [convert(item, depth + 1) for item in node.value]
        if isinstance(node, MappingNode):
            result = {}
            for key_node, value_node in node.value:
                if not isinstance(key_node, ScalarNode):
                    raise ValueError("Non-scalar mapping key")
                key = convert(key_node, depth + 1)
                if not isinstance(key, str) or key == "<<" or key in result:
                    raise ValueError("Invalid or duplicate mapping key")
                result[key] = convert(value_node, depth + 1)
            return result
        raise ValueError("Unsupported YAML node")

    result = convert(yaml.compose(text, Loader=yaml.BaseLoader))
    if not isinstance(result, dict):
        raise ValueError("Tool arguments must be an object")
    return result


if __name__ == "__main__":
    try:
        raw = sys.stdin.buffer.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            raise ValueError("Input limit exceeded")
        output = json.dumps(decode(raw.decode("utf-8")), allow_nan=False, ensure_ascii=True)
        if len(output) > 2 * MAX_BYTES:
            raise ValueError("Output limit exceeded")
        sys.stdout.write(output)
    except Exception:
        sys.exit(1)
