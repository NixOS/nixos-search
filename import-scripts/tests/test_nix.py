import pytest  # type: ignore


@pytest.mark.parametrize(
    "item,expected",
    [
        (None, "null",),
        (True, "true",),
        ("text", '"text"',),
        (
            "\nnew line is ignored at start and end\n",
            '"new line is ignored at start and end"',
        ),
        ('"double quotes"', '"\\"double quotes\\""',),
        ("multi\nline\ntext", "''\n  multi\n  line\n  text\n''",),
        ('"multi line\ndouble quotes"', "''\n  \"multi line\n  double quotes\"\n''",),
        (123, "123",),
        (123.123, "123.123",),
        (
            [False, "text", "multi\nline\ntext"],
            "".join(
                [
                    "[\n",
                    "  false\n",
                    '  "text"\n',
                    "  ''\n    multi\n" "    line\n" "    text\n" "  ''\n" "]",
                ]
            ),
        ),
        (
            {"name1": "value1", "name.2": True, "name3": [False, "text"]},
            (
                "{\n"
                '  name1 = "value1";\n'
                '  "name.2" = true;\n'
                "  name3 = [\n"
                "    false\n"
                '    "text"\n'
                "  ];\n"
                "}"
            ),
        ),
        (
            [{"name1": ["value1", "value2"]}],
            (
                "[\n"
                "  {\n"
                "    name1 = [\n"
                '      "value1"\n'
                '      "value2"\n'
                "    ];\n"
                "  }\n"
                "]"
            ),
        ),
    ],
)
def test_convert(item, expected):
    import import_scripts.nix

    assert import_scripts.nix.prettyPrint(item) == expected
