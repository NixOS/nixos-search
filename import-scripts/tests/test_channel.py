import pytest  # type: ignore


@pytest.mark.parametrize(
    "text,expected",
    [
        (
            "services.nginx.extraConfig",
            [
                "services.nginx.extraConfig",
                "services.nginx.extra",
                "services.nginx",
                "services",
                "nginx.extraConfig",
                "nginx.extra",
                "nginx",
                "extraConfig",
                "extra",
                "Config",
            ],
        ),
        (
            "python37Packages.test1_name-test2",
            [
                "python37Packages.test1_name-test2",
                "python37Packages.test1_name-test",
                "python37Packages.test1_name",
                "python37Packages.test1",
                "python37Packages.test",
                "python37Packages",
                "python37",
                "python",
                "37Packages.test1_name-test2",
                "37Packages.test1_name-test",
                "37Packages.test1_name",
                "37Packages.test1",
                "37Packages.test",
                "37Packages",
                "37",
                "Packages.test1_name-test2",
                "Packages.test1_name-test",
                "Packages.test1_name",
                "Packages.test1",
                "Packages.test",
                "Packages",
                "test1_name-test2",
                "test1_name-test",
                "test1_name",
                "test1",
                "test",
                "1_name-test2",
                "1_name-test",
                "1_name",
                "1",
                "name-test2",
                "name-test",
                "name",
                "test2",
                "test",
                "2",
            ],
        ),
    ],
)
def test_parse_query(text, expected):
    import import_scripts.channel

    assert sorted(import_scripts.channel.parse_query(text)) == sorted(expected)


@pytest.mark.parametrize(
    "field,expected",
    [
        ("example", "elpmaxe"),
        ("example two", "elpmaxe owt"),
        (["example", "three"], ["elpmaxe", "eerht"]),
        (("example", "three"), ("elpmaxe", "eerht")),
    ],
)
def test_field_reverse(field, expected):
    import import_scripts.channel

    assert import_scripts.channel.field_reverse(field) == expected
