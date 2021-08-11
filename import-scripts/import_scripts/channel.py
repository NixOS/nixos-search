import backoff  # type: ignore
import boto3  # type: ignore
import botocore  # type: ignore
import botocore.client  # type: ignore
import botocore.exceptions  # type: ignore
import click
import click_log  # type: ignore
import dictdiffer  # type: ignore
import elasticsearch  # type: ignore
import elasticsearch.helpers  # type: ignore
import import_scripts.nix  # type: ignore
import json
import logging
import os
import os.path
import pypandoc  # type: ignore
import re
import requests
import requests.exceptions
import shlex
import subprocess
import sys
import tqdm  # type: ignore
import xml.etree.ElementTree

logger = logging.getLogger("import-channel")
click_log.basic_config(logger)


S3_BUCKET = "nix-releases"
CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
INDEX_SCHEMA_VERSION = os.environ.get("INDEX_SCHEMA_VERSION", 0)
DIFF_OUTPUT = ["json", "stats"]
CHANNELS = {
    "unstable": "nixos/unstable/nixos-21.11pre",
    "21.05": "nixos/21.05/nixos-21.05.",
    "20.09": "nixos/20.09/nixos-20.09.",
}
ALLOWED_PLATFORMS = ["x86_64-linux", "aarch64-linux", "x86_64-darwin", "i686-linux"]
ANALYSIS = {
    "normalizer": {
        "lowercase": {"type": "custom", "char_filter": [], "filter": ["lowercase"]}
    },
    "tokenizer": {
        "edge": {
            "type": "edge_ngram",
            "min_gram": 2,
            "max_gram": 50,
            "token_chars": [
                "letter",
                "digit",
                # Either we use them or we would need to strip them before that.
                "punctuation",
                "symbol",
            ],
        },
    },
    "analyzer": {
        "edge": {"tokenizer": "edge", "filter": ["lowercase"]},
        "lowercase": {
            "type": "custom",
            "tokenizer": "keyword",
            "filter": ["lowercase"],
        },
    },
}
MAPPING = {
    "properties": {
        "type": {"type": "keyword"},
        # Package fields
        "package_hydra_build": {
            "type": "nested",
            "properties": {
                "build_id": {"type": "keyword"},
                "build_status": {"type": "keyword"},
                "platform": {"type": "keyword"},
                "project": {"type": "keyword"},
                "jobset": {"type": "keyword"},
                "job": {"type": "keyword"},
                "path": {
                    "type": "nested",
                    "properties": {
                        "output": {"type": "keyword"},
                        "path": {"type": "keyword"},
                    },
                },
                "drv_path": {"type": "keyword"},
            },
        },
        "package_attr_name": {
            "type": "keyword",
            "fields": {"edge": {"type": "text", "analyzer": "edge"}},
        },
        "package_attr_name_reverse": {
            "type": "keyword",
            "fields": {"edge": {"type": "text", "analyzer": "edge"}},
        },
        "package_attr_name_query": {
            "type": "keyword",
            "fields": {"edge": {"type": "text", "analyzer": "edge"}},
        },
        "package_attr_name_query_reverse": {
            "type": "keyword",
            "fields": {"edge": {"type": "text", "analyzer": "edge"}},
        },
        "package_attr_set": {
            "type": "keyword",
            "fields": {"edge": {"type": "text", "analyzer": "edge"}},
        },
        "package_attr_set_reverse": {
            "type": "keyword",
            "fields": {"edge": {"type": "text", "analyzer": "edge"}},
        },
        "package_pname": {
            "type": "keyword",
            "fields": {"edge": {"type": "text", "analyzer": "edge"}},
        },
        "package_pname_reverse": {
            "type": "keyword",
            "fields": {"edge": {"type": "text", "analyzer": "edge"}},
        },
        "package_pversion": {"type": "keyword"},
        "package_description": {
            "type": "text",
            "analyzer": "english",
            "fields": {"edge": {"type": "text", "analyzer": "edge"}},
        },
        "package_description_reverse": {
            "type": "text",
            "analyzer": "english",
            "fields": {"edge": {"type": "text", "analyzer": "edge"}},
        },
        "package_longDescription": {
            "type": "text",
            "analyzer": "english",
            "fields": {"edge": {"type": "text", "analyzer": "edge"}},
        },
        "package_longDescription_reverse": {
            "type": "text",
            "analyzer": "english",
            "fields": {"edge": {"type": "text", "analyzer": "edge"}},
        },
        "package_license": {
            "type": "nested",
            "properties": {"fullName": {"type": "text"}, "url": {"type": "text"}},
        },
        "package_license_set": {"type": "keyword"},
        "package_maintainers": {
            "type": "nested",
            "properties": {
                "name": {"type": "text"},
                "email": {"type": "text"},
                "github": {"type": "text"},
            },
        },
        "package_maintainers_set": {"type": "keyword"},
        "package_platforms": {"type": "keyword"},
        "package_position": {"type": "text"},
        "package_homepage": {"type": "keyword"},
        "package_system": {"type": "keyword"},
        # Options fields
        "option_name": {
            "type": "keyword",
            "fields": {"edge": {"type": "text", "analyzer": "edge"}},
        },
        "option_name_reverse": {
            "type": "keyword",
            "fields": {"edge": {"type": "text", "analyzer": "edge"}},
        },
        "option_name_query": {
            "type": "keyword",
            "fields": {"edge": {"type": "text", "analyzer": "edge"}},
        },
        "option_name_query_reverse": {
            "type": "keyword",
            "fields": {"edge": {"type": "text", "analyzer": "edge"}},
        },
        "option_description": {
            "type": "text",
            "analyzer": "english",
            "fields": {"edge": {"type": "text", "analyzer": "edge"}},
        },
        "option_description_reverse": {
            "type": "text",
            "analyzer": "english",
            "fields": {"edge": {"type": "text", "analyzer": "edge"}},
        },
        "option_type": {"type": "keyword"},
        "option_default": {"type": "text"},
        "option_example": {"type": "text"},
        "option_source": {"type": "keyword"},
    },
}


def string_reverse(text):
    return text[::-1]


def field_reverse(field):

    if isinstance(field, str):

        if " " in field:
            field = " ".join(map(field_reverse, field.split(" ")))
        else:
            field = string_reverse(field)

    elif isinstance(field, list):
        field = list(map(field_reverse, field))

    elif isinstance(field, tuple):
        field = tuple(map(field_reverse, field))

    elif field is None:
        pass

    else:
        raise NotImplementedError(f"Don't know how to reverse {field}")

    return field


def parse_query(text):
    """Tokenize package attr_name

    Example package:

    python37Packages.test_name-test
     = index: 0
     - python37Packages.test1_name-test2
     - python37Packages.test1_name
     - python37Packages.test1
     - python37
     - python
     = index: 1
     - test1_name-test2
     - test1_name
     - test1
     = index: 2
     - name-test2
     - name
     = index: 3
     - test2
    """
    tokens = []
    regex = re.compile(
        ".+?(?:(?<=[a-z])(?=[1-9A-Z])|(?<=[1-9A-Z])(?=[A-Z][a-z])|[._-]|$)"
    )
    parts = [m.group(0) for m in regex.finditer(text)]
    for index in range(len(parts)):
        prev_parts = ""
        for part in parts[index:]:
            tokens.append((prev_parts + part).rstrip("_.-"))
            prev_parts += part
    return tokens


@backoff.on_exception(backoff.expo, botocore.exceptions.ClientError)
def get_last_evaluation(prefix):
    logger.debug(f"Retrieving last evaluation for {prefix} prefix.")

    s3 = boto3.client(
        "s3", config=botocore.client.Config(signature_version=botocore.UNSIGNED)
    )
    s3_result = s3.list_objects(Bucket=S3_BUCKET, Prefix=prefix, Delimiter="/",)
    evaluations = []
    for item in s3_result.get("CommonPrefixes"):
        if not item:
            continue
        logger.debug(f"get_last_evaluation: evaluation in raw {item}")
        revisions_since_start, git_revision = (
            item["Prefix"][len(prefix) :].rstrip("/").split(".")
        )
        evaluation = {
            "revisions_since_start": int(revisions_since_start),
            "git_revision": git_revision,
            "prefix": item["Prefix"].rstrip("/"),
        }
        logger.debug(f"get_last_evaluation: evaluation {evaluation}")
        evaluations.append(evaluation)

    logger.debug(
        f"get_last_evaluation: {len(evaluations)} evaluations found for {prefix} prefix"
    )
    evaluations = sorted(evaluations, key=lambda i: i["revisions_since_start"])

    evaluation = evaluations[-1]

    result = s3.get_object(Bucket=S3_BUCKET, Key=f"{evaluation['prefix']}/src-url")
    evaluation["id"] = (
        result.get("Body").read().decode()[len("https://hydra.nixos.org/eval/") :]
    )

    logger.debug(f"get_last_evaluation: last evaluation is: {evaluation}")

    return evaluation


@backoff.on_exception(backoff.expo, requests.exceptions.RequestException)
def get_evaluation_builds(evaluation_id):
    logger.debug(
        f"get_evaluation_builds: Retrieving list of builds for {evaluation_id} evaluation id"
    )
    filename = f"eval-{evaluation_id}.json"
    if not os.path.exists(filename):
        url = f"https://hydra.nixos.org/eval/{evaluation_id}/builds"
        logger.debug(f"get_evaluation_builds: Fetching builds from {url} url.")
        headers = {"Content-Type": "application/json"}
        r = requests.get(url, headers=headers, stream=True)
        with tqdm.tqdm.wrapattr(
            open(filename, "wb"),
            "write",
            miniters=1,
            total=int(r.headers.get("content-length", 0)),
            desc=filename,
        ) as f:
            for chunk in r.iter_content(chunk_size=4096):
                f.write(chunk)

    with open(filename) as f:
        builds = json.loads(f.read())

    result = {}
    for build in builds:
        result.setdefault(build["nixname"], {})
        result[build["nixname"]][build["system"]] = build

    return result


def get_maintainer(maintainer):
    maintainers = []

    if type(maintainer) == str:
        maintainers.append(dict(name=maintainer, email=None, github=None,))

    elif type(maintainer) == dict:
        maintainers.append(
            dict(
                name=maintainer.get("name"),
                email=maintainer.get("email"),
                github=maintainer.get("github"),
            )
        )

    elif type(maintainer) == list:
        for item in maintainer:
            maintainers += get_maintainer(item)

    else:
        logger.error(f"maintainer  can not be recognized from: {maintainer}")
        sys.exit(1)

    return maintainers


def remove_attr_set(name):
    # some package sets the prefix is included in pname
    sets = [
        # Packages
        "emscripten",
        "lua",
        "php",
        "pure",
        "python",
        "lisp",
        "perl",
        "ruby",
        # Plugins
        "elasticsearch",
        "graylog",
        "tmuxplugin",
        "vimplugin",
    ]
    # TODO: is this correct
    if any([name.startswith(i) for i in sets]):
        name = "-".join(name.split("-")[1:])

    # node does things a bit different
    elif name.startswith("node_"):
        name = name[len("node_") :]

    return name


@backoff.on_exception(backoff.expo, subprocess.CalledProcessError)
def get_packages_raw(evaluation):
    logger.debug(
        f"get_packages_raw: Retrieving list of packages for '{evaluation['git_revision']}' revision"
    )
    result = subprocess.run(
        shlex.split(
            f"nix-env -f '<nixpkgs>' -I nixpkgs=https://github.com/NixOS/nixpkgs/archive/{evaluation['git_revision']}.tar.gz --arg config 'import {CURRENT_DIR}/packages-config.nix' -qa --json"
        ),
        stdout=subprocess.PIPE,
        check=True,
    )
    packages = json.loads(result.stdout).items()
    return list(packages)


def get_packages(evaluation, evaluation_builds):
    packages = list(get_packages_raw(evaluation))

    def gen():
        for attr_name, data in packages:
            licenses = data["meta"].get("license")
            if licenses:
                if type(licenses) == str:
                    licenses = [dict(fullName=licenses, url=None)]
                elif type(licenses) == dict:
                    licenses = [licenses]
                licenses = [
                    type(license) == str
                    and dict(fullName=license, url=None)
                    or dict(fullName=license.get("fullName"), url=license.get("url"),)
                    for license in licenses
                ]
            else:
                licenses = [dict(fullName="No license", url=None)]

            maintainers = get_maintainer(data["meta"].get("maintainers", []))
            if len(maintainers) == 0:
                maintainers = [dict(name="No maintainers", email=None, github=None)]

            platforms = [
                platform
                for platform in data["meta"].get("platforms", [])
                if type(platform) == str and platform in ALLOWED_PLATFORMS
            ]

            attr_set = "No package set"
            if "." in attr_name:
                maybe_attr_set = attr_name.split(".")[0]
                if (
                    maybe_attr_set.endswith("Packages")
                    or maybe_attr_set.endswith("Plugins")
                    or maybe_attr_set.endswith("Extensions")
                ):
                    attr_set = maybe_attr_set

            hydra = None
            if data["name"] in evaluation_builds:
                hydra = []
                for platform, build in evaluation_builds[data["name"]].items():
                    hydra.append(
                        {
                            "build_id": build["id"],
                            "build_status": build["buildstatus"],
                            "platform": build["system"],
                            "project": build["project"],
                            "jobset": build["jobset"],
                            "job": build["job"],
                            "path": [
                                {"output": output, "path": item["path"]}
                                for output, item in build["buildoutputs"].items()
                            ],
                            "drv_path": build["drvpath"],
                        }
                    )

            position = data["meta"].get("position")
            if position and position.startswith("/nix/store"):
                position = position.split("/", 4)[-1]

            package_attr_name_query = list(parse_query(attr_name))
            package_pname = remove_attr_set(data["pname"])
            package_description = data["meta"].get("description")
            package_longDescription = data["meta"].get("longDescription", "")

            yield dict(
                type="package",
                package_hydra=hydra,
                package_attr_name=attr_name,
                package_attr_name_reverse=field_reverse(attr_name),
                package_attr_name_query=package_attr_name_query,
                package_attr_name_query_reverse=field_reverse(package_attr_name_query),
                package_attr_set=attr_set,
                package_attr_set_reverse=field_reverse(attr_set),
                package_pname=package_pname,
                package_pname_reverse=field_reverse(package_pname),
                package_pversion=data["version"],
                package_description=package_description,
                package_description_reverse=field_reverse(package_description),
                package_longDescription=package_longDescription,
                package_longDescription_reverse=field_reverse(package_longDescription),
                package_license=licenses,
                package_license_set=[i["fullName"] for i in licenses],
                package_maintainers=maintainers,
                package_maintainers_set=[i["name"] for i in maintainers if i["name"]],
                package_platforms=platforms,
                package_position=position,
                package_homepage=data["meta"].get("homepage"),
                package_system=data["system"],
            )

    logger.debug(f"get_packages: Found {len(packages)} packages")
    return len(packages), gen


@backoff.on_exception(backoff.expo, subprocess.CalledProcessError)
def get_options_raw(evaluation):
    logger.debug(
        f"get_options: Retrieving list of options for '{evaluation['git_revision']}' revision"
    )
    result = subprocess.run(
        shlex.split(
            f"nix-build <nixpkgs/nixos/release.nix> --no-out-link -A options -I nixpkgs=https://github.com/NixOS/nixpkgs/archive/{evaluation['git_revision']}.tar.gz"
        ),
        stdout=subprocess.PIPE,
        check=True,
    )
    options = []
    options_file = result.stdout.strip().decode()
    options_file = f"{options_file}/share/doc/nixos/options.json"
    if os.path.exists(options_file):
        with open(options_file) as f:
            options = json.load(f).items()
    return list(options)


def get_options(evaluation):
    options = get_options_raw(evaluation)

    def gen():
        for name, option in options:
            if "default" in option:
                default = import_scripts.nix.prettyPrint(option.get("default"))
            else:
                default = None

            if "example" in option:
                example = import_scripts.nix.prettyPrint(option.get("example"))
            else:
                example = None

            description = option.get("description")
            if description is not None:
                xml_description = (
                    f'<xml xmlns:xlink="http://www.w3.org/1999/xlink">'
                    f"<para>{description}</para>"
                    f"</xml>"
                )
                # we first check if there are some xml elements before using pypandoc
                # since pypandoc calls are quite slow
                root = xml.etree.ElementTree.fromstring(xml_description)
                if len(list(root.find("para"))) > 0:
                    description = pypandoc.convert_text(
                        xml_description, "html", format="docbook",
                    )

            option_name_query = parse_query(name)

            declarations = option.get("declarations", [])
            option_source = declarations[0] if declarations else None

            yield dict(
                type="option",
                option_name=name,
                option_name_reverse=field_reverse(name),
                option_name_query=option_name_query,
                option_name_query_reverse=field_reverse(option_name_query),
                option_description=description,
                option_description_reverse=field_reverse(description),
                option_type=option.get("type"),
                option_default=default,
                option_example=example,
                option_source=option_source,
            )

    return len(options), gen


def ensure_index(es, index, mapping, force=False):
    if es.indices.exists(index):
        logger.debug(f"ensure_index: index '{index}' already exists")
        if not force:
            return False

        logger.debug(f"ensure_index: Deleting index '{index}'")
        es.indices.delete(index)

    es.indices.create(
        index=index,
        body={
            "settings": {"number_of_shards": 1, "analysis": ANALYSIS},
            "mappings": mapping,
        },
    )
    logger.debug(f"ensure_index: index '{index}' was created")

    return True


def create_index_name(channel, evaluation):
    evaluation_name = "-".join(
        [
            evaluation["id"],
            str(evaluation["revisions_since_start"]),
            evaluation["git_revision"],
            evaluation["id"],
            str(evaluation["revisions_since_start"]),
            evaluation["git_revision"],
        ]
    )
    return (
        f"latest-{INDEX_SCHEMA_VERSION}-{channel}",
        f"evaluation-{INDEX_SCHEMA_VERSION}-{channel}-{evaluation_name}",
    )


def update_alias(es, name, index):
    if es.indices.exists_alias(name=name):
        indexes = set(es.indices.get_alias(name=name).keys())

        # indexes to remove from alias
        actions = [
            {"remove": {"index": item, "alias": name}}
            for item in indexes.difference(set([index]))
        ]

        # add index if does not exists in alias
        if index not in indexes:
            actions.append({"add": {"index": index, "alias": name}})

        if actions:
            es.indices.update_aliases({"actions": actions})
    else:
        es.indices.put_alias(index=index, name=name)

    indexes = ", ".join(es.indices.get_alias(name=name).keys())
    logger.debug(f"'{name}' alias now points to '{indexes}' index")


def write(unit, es, index_name, number_of_items, item_generator):
    if number_of_items:
        click.echo(f"Indexing {unit}...")
        progress = tqdm.tqdm(unit=unit, total=number_of_items)
        successes = 0
        for ok, action in elasticsearch.helpers.streaming_bulk(
            client=es, index=index_name, actions=item_generator()
        ):
            progress.update(1)
            successes += ok
        click.echo(f"Indexed {successes}/{number_of_items} {unit}")


def setup_logging(verbose):
    logging_level = "CRITICAL"
    if verbose == 1:
        logging_level = "WARNING"
    elif verbose >= 2:
        logging_level = "DEBUG"

    logger.setLevel(getattr(logging, logging_level))
    logger.debug(f"Verbosity is {verbose}")
    logger.debug(f"Logging set to {logging_level}")


@click.command()
@click.option("-u", "--es-url", help="Elasticsearch connection url.")
@click.option("-c", "--channel", type=click.Choice(CHANNELS.keys()), help="Channel.")
@click.option("-f", "--force", is_flag=True, help="Force channel recreation.")
@click.option("-v", "--verbose", count=True)
def run_import(es_url, channel, force, verbose):
    setup_logging(verbose)

    evaluation = get_last_evaluation(CHANNELS[channel])
    evaluation_builds = dict()
    # evaluation_builds = get_evaluation_builds(evaluation["id"])

    es = elasticsearch.Elasticsearch([es_url])

    alias_name, index_name = create_index_name(channel, evaluation)
    index_created = ensure_index(es, index_name, MAPPING, force)

    if index_created:
        write(
            "packages", es, index_name, *get_packages(evaluation, evaluation_builds),
        )
        write("options", es, index_name, *get_options(evaluation))

    update_alias(es, alias_name, index_name)


def prepare_items(key, total, func):
    logger.info(f"Preparing items ({key})...")
    return {item[key]: item for item in func()}


def get_packages_diff(evaluation):
    for attr_name, data in get_packages_raw(evaluation):
        data_cmp = dict(attr_name=attr_name, version=data.get("version"),)
        yield attr_name, data_cmp, data


def get_options_diff(evaluation):
    for name, data in get_options_raw(evaluation):
        data_cmp = dict(name=name, type=data.get("type"), default=data.get("default"),)
        yield name, data_cmp, data


def create_diff(type_, items_from, items_to):
    logger.debug(f"Starting to diff {type_}...")
    return dict(
        added=[item for key, item in items_to.items() if key not in items_from.keys()],
        removed=[
            item for key, item in items_from.items() if key not in items_to.keys()
        ],
        updated=[
            (
                list(dictdiffer.diff(items_from[key][0], items_to[key][0])),
                items_from[key],
                items_to[key],
            )
            for key in set(items_from.keys()).intersection(set(items_to.keys()))
            if items_from[key][0] != items_to[key][0]
        ],
    )


@click.command()
@click.option("-v", "--verbose", count=True)
@click.option("-o", "--output", default="stats", type=click.Choice(DIFF_OUTPUT))
@click.argument("channel_from", type=click.Choice(CHANNELS.keys()))
@click.argument("channel_to", type=click.Choice(CHANNELS.keys()))
def run_diff(channel_from, channel_to, output, verbose):
    setup_logging(verbose)

    # TODO: channel_from and channel_to should not be the same

    evaluation_from = get_last_evaluation(CHANNELS[channel_from])
    evaluation_to = get_last_evaluation(CHANNELS[channel_to])

    packages_from = {
        key: (item, item_raw)
        for key, item, item_raw in get_packages_diff(evaluation_from)
    }
    packages_to = {
        key: (item, item_raw)
        for key, item, item_raw in get_packages_diff(evaluation_to)
    }

    options_from = {
        key: (item, item_raw)
        for key, item, item_raw in get_options_diff(evaluation_from)
    }
    options_to = {
        key: (item, item_raw) for key, item, item_raw in get_options_diff(evaluation_to)
    }

    packages_diff = create_diff("packages", packages_from, packages_to)
    options_diff = create_diff("options", options_from, options_to)

    if output == "stats":
        click.echo("Packages:")
        click.echo(f"  All in {channel_from}: {len(packages_from)}")
        click.echo(f"  All in {channel_to}: {len(packages_to)}")
        click.echo(f"  Added: {len(packages_diff['added'])}")
        click.echo(f"  Removed: {len(packages_diff['removed'])}")
        click.echo(f"  Updated: {len(packages_diff['updated'])}")
        click.echo("Options:")
        click.echo(f"  All in {channel_from}: {len(options_from)}")
        click.echo(f"  All in {channel_to}: {len(options_to)}")
        click.echo(f"  Added: {len(options_diff['added'])}")
        click.echo(f"  Removed: {len(options_diff['removed'])}")
        click.echo(f"  Updated: {len(options_diff['updated'])}")
    elif output == "json":
        click.echo(json.dumps(dict(packages=packages_diff, options=options_diff,)))
    else:
        click.echo(f"ERROR: unknown output {output}")


if __name__ == "__main__":
    run_import()
