import pytest  # type: ignore


@pytest.mark.parametrize(
    "item,expected",
    [
        (None, "null",),
        (True, "true",),
        ("text", '"text"',),
        (123, "123",),
        (123.123, "123.123",),
        ([False, "text"], ("[\n" "  false\n" '  "text"\n' "]"),),
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
