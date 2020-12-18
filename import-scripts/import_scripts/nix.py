def prettyPrintAttrName(attr_name):
    if "." in attr_name:
        return prettyPrint(attr_name)
    return attr_name


stringEscapes = str.maketrans({"\\": "\\\\", '"': '\\"'})


def prettyPrint(item, level=""):
    next_level = level + "  "

    if item is None:
        return "null"

    elif type(item) == bool:
        if item:
            return "true"
        return "false"

    elif type(item) in (int, float):
        return f"{item}"

    elif type(item) == str:
        item = item.strip()
        if "\n" in item:
            return "".join(
                [
                    "''\n",
                    "".join(
                        [
                            f"{next_level}{line}"
                            for line in item.splitlines(keepends=True)
                        ]
                    ),
                    f"\n{level}''",
                ]
            )
        return f'"{item.translate(stringEscapes)}"'

    elif type(item) == list:
        if len(item) == 0:
            return "[ ]"
        return (
            "[\n"
            + ("".join([f"{next_level}{prettyPrint(i, next_level)}\n" for i in item]))
            + f"{level}]"
        )

    elif type(item) == dict:
        if len(item) == 0:
            return "{ }"
        if item.get("_type") == "literalExample":
            if type(item["text"]) == str:
                return item["text"]
            else:
                return prettyPrint(item["text"], level)
        return (
            "{\n"
            + (
                "".join(
                    [
                        f"{next_level}{prettyPrintAttrName(n)} = {prettyPrint(v, next_level)};\n"
                        for n, v in item.items()
                    ]
                )
            )
            + f"{level}}}"
        )

    else:
        raise NotImplementedError(item)
