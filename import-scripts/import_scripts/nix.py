def prettyPrintAttrName(attr_name):
    if "." in attr_name:
        return prettyPrint(attr_name)
    return attr_name


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
        if "\n" in item:
            return f"''{item}''"
        return f'"{item}"'

    elif type(item) == list:
        if len(item) == 0:
            return "[ ]"
        return (
            "[\n"
            + ("".join([f"{level}  {prettyPrint(i, next_level)}\n" for i in item]))
            + f"{level}]"
        )

    elif type(item) == dict:
        if len(item) == 0:
            return "{ }"
        if item.get("_type") == "literalExample":
            if type(item["text"]) == str:
                return item["text"]
            else:
                return prettyPrint(item["text"], next_level)
        return (
            "{\n"
            + (
                "".join(
                    [
                        f"{level}  {prettyPrintAttrName(n)} = {prettyPrint(v, next_level)};\n"
                        for n, v in item.items()
                    ]
                )
            )
            + f"{level}}}"
        )

    else:
        raise NotImplementedError(item)
