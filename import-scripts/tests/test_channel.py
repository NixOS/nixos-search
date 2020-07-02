import pytest  # type: ignore


@pytest.mark.parametrize(
    "text,expected",
    [
        (
            "services.grafana.analytics.reporting.enable",
            [
                {"input": "services.grafana.analytics.reporting.enable", "weight": 960},
                {"input": "services.grafana.analytics.reporting.", "weight": 971},
                {"input": "services.grafana.analytics.", "weight": 981},
                {"input": "services.grafana.", "weight": 991},
                {"input": "services.", "weight": 1001},
            ],
        ),
        (
            "services.nginx.extraConfig",
            [
                {"input": "services.nginx.extraConfig", "weight": 980},
                {"input": "services.nginx.", "weight": 991},
                {"input": "services.", "weight": 1001},
            ],
        ),
        (
            "python37Packages.test1_name-test2",
            [
                {"input": "python37Packages.test1_name-test2", "weight": 990},
                {"input": "python37Packages.", "weight": 1001},
            ],
        ),
    ],
)
def test_parse_suggestions(text, expected):
    import import_scripts.channel

    assert import_scripts.channel.parse_suggestions(text) == expected


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
