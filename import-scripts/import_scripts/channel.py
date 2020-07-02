import boto3  # type: ignore
import botocore  # type: ignore
import botocore.client  # type: ignore
import click
import click_log  # type: ignore
import elasticsearch  # type: ignore
import elasticsearch.helpers  # type: ignore
import json
import logging
import os
import os.path
import pypandoc  # type: ignore
import re
import requests
import shlex
import subprocess
import sys
import tqdm  # type: ignore
import typing
import xml.etree.ElementTree

logger = logging.getLogger("import-channel")
click_log.basic_config(logger)


S3_BUCKET = "nix-releases"
CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
INDEX_SCHEMA_VERSION = os.environ.get("INDEX_SCHEMA_VERSION", 0)
CHANNELS = {
    "unstable": {
        "packages": "nixpkgs/nixpkgs-20.09pre",
        "options": "nixos/unstable/nixos-20.09pre",
    },
    "19.09": {
        "packages": "nixpkgs/nixpkgs-19.09pre",
        "options": "nixos/19.09/nixos-19.09.",
    },
    "20.03": {
        "packages": "nixpkgs/nixpkgs-20.03pre",
        "options": "nixos/20.03/nixos-20.03.",
    },
}
ANALYSIS = {
    "normalizer": {
        "lowercase": {"type": "custom", "char_filter": [], "filter": ["lowercase"]}
    },
    "analyzer": {
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
        "package_suggestions": {
            "type": "completion",
            "analyzer": "lowercase",
            "search_analyzer": "lowercase",
            "preserve_position_increments": False,
        },
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
        "package_attr_name": {"type": "keyword", "normalizer": "lowercase"},
        "package_attr_name_query": {"type": "keyword", "normalizer": "lowercase"},
        "package_attr_set": {"type": "keyword", "normalizer": "lowercase"},
        "package_pname": {"type": "keyword", "normalizer": "lowercase"},
        "package_pversion": {"type": "keyword"},
        "package_description": {"type": "text"},
        "package_longDescription": {"type": "text"},
        "package_license": {
            "type": "nested",
            "properties": {"fullName": {"type": "text"}, "url": {"type": "text"}},
        },
        "package_maintainers": {
            "type": "nested",
            "properties": {
                "name": {"type": "text"},
                "email": {"type": "text"},
                "github": {"type": "text"},
            },
        },
        "package_platforms": {"type": "keyword"},
        "package_position": {"type": "text"},
        "package_homepage": {"type": "keyword"},
        "package_system": {"type": "keyword"},
        # Options fields
        "option_suggestions": {
            "type": "completion",
            "analyzer": "lowercase",
            "search_analyzer": "lowercase",
            "preserve_position_increments": False,
        },
        "option_name": {"type": "keyword", "normalizer": "lowercase"},
        "option_name_query": {"type": "keyword", "normalizer": "lowercase"},
        "option_description": {"type": "text"},
        "option_type": {"type": "keyword"},
        "option_default": {"type": "text"},
        "option_example": {"type": "text"},
        "option_source": {"type": "keyword"},
    },
}


def parse_suggestions(text: str) -> typing.List[typing.Dict[str, object]]:
    """Tokenize option_name

    Example:

    services.nginx.extraConfig
     - services.nginx.extraConfig
     - services.nginx.
     - services.
    """
    results: typing.List[typing.Dict[str, object]] = [
        {"input": text, "weight": 1000 - (((len(text.split(".")) - 1) * 10))},
    ]
    for i in range(len(text.split(".")) - 1):
        result = {
            "input": ".".join(text.split(".")[: -(i + 1)]) + ".",
            "weight": 1000 - ((len(text.split(".")) - 2 - i) * 10) + 1,
        }
        results.append(result)
    return results


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


def get_last_evaluation(prefix):
    logger.debug(f"Retriving last evaluation for {prefix} prefix.")

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


def get_evaluation_builds(evaluation_id):
    logger.debug(
        f"get_evaluation_builds: Retriving list of builds for {evaluation_id} evaluation id"
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


def get_packages(evaluation, evaluation_builds):
    logger.debug(
        f"get_packages: Retriving list of packages for '{evaluation['git_revision']}' revision"
    )
    result = subprocess.run(
        shlex.split(
            f"nix-env -f '<nixpkgs>' -I nixpkgs=https://github.com/NixOS/nixpkgs-channels/archive/{evaluation['git_revision']}.tar.gz --arg config 'import {CURRENT_DIR}/packages-config.nix' -qa --json"
        ),
        stdout=subprocess.PIPE,
        check=True,
    )
    packages = json.loads(result.stdout).items()
    packages = list(packages)

    def gen():
        for attr_name, data in packages:

            position = data["meta"].get("position")
            if position and position.startswith("/nix/store"):
                position = position[44:]

            licenses = data["meta"].get("license")
            if licenses:
                if type(licenses) == str:
                    licenses = [dict(fullName=licenses)]
                elif type(licenses) == dict:
                    licenses = [licenses]
                licenses = [
                    type(license) == str
                    and dict(fullName=license, url=None)
                    or dict(fullName=license.get("fullName"), url=license.get("url"),)
                    for license in licenses
                ]
            else:
                licenses = []

            maintainers = get_maintainer(data["meta"].get("maintainers", []))

            platforms = [
                type(platform) == str and platform or None
                for platform in data["meta"].get("platforms", [])
            ]

            attr_set = None
            if "." in attr_name:
                attr_set = attr_name.split(".")[0]
                if (
                    not attr_set.endswith("Packages")
                    and not attr_set.endswith("Plugins")
                    and not attr_set.endswith("Extensions")
                ):
                    attr_set = None

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

            yield dict(
                type="package",
                package_suggestions=parse_suggestions(attr_name),
                package_hydra=hydra,
                package_attr_name=attr_name,
                package_attr_name_query=list(parse_query(attr_name)),
                package_attr_set=attr_set,
                package_pname=remove_attr_set(data["pname"]),
                package_pversion=data["version"],
                package_description=data["meta"].get("description"),
                package_longDescription=data["meta"].get("longDescription", ""),
                package_license=licenses,
                package_maintainers=maintainers,
                package_platforms=[i for i in platforms if i],
                package_position=position,
                package_homepage=data["meta"].get("homepage"),
                package_system=data["system"],
            )

    logger.debug(f"get_packages: Found {len(packages)} packages")
    return len(packages), gen


def get_options(evaluation):
    result = subprocess.run(
        shlex.split(
            f"nix-build <nixpkgs/nixos/release.nix> --no-out-link -A options -I nixpkgs=https://github.com/NixOS/nixpkgs-channels/archive/{evaluation['git_revision']}.tar.gz"
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
    options = list(options)

    def gen():
        for name, option in options:
            default = option.get("default")
            if default is not None:
                default = json.dumps(default)

            example = option.get("example")
            if example is not None:
                if type(example) == dict and example.get("_type") == "literalExample":
                    example = json.dumps(example["text"])
                else:
                    example = json.dumps(example)

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

            yield dict(
                type="option",
                option_suggestions=parse_suggestions(name),
                option_name=name,
                option_name_query=parse_query(name),
                option_description=description,
                option_type=option.get("type"),
                option_default=default,
                option_example=example,
                option_source=option.get("declarations", [None])[0],
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


def create_index_name(channel, evaluation_packages, evaluation_options):
    evaluation_name = "-".join(
        [
            evaluation_packages["id"],
            str(evaluation_packages["revisions_since_start"]),
            evaluation_packages["git_revision"],
            evaluation_options["id"],
            str(evaluation_options["revisions_since_start"]),
            evaluation_options["git_revision"],
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


@click.command()
@click.option("-u", "--es-url", help="Elasticsearch connection url.")
@click.option("-c", "--channel", type=click.Choice(CHANNELS.keys()), help="Channel.")
@click.option("-f", "--force", is_flag=True, help="Force channel recreation.")
@click.option("-v", "--verbose", count=True)
def run(es_url, channel, force, verbose):

    logging_level = "CRITICAL"
    if verbose == 1:
        logging_level = "WARNING"
    elif verbose >= 2:
        logging_level = "DEBUG"

    logger.setLevel(getattr(logging, logging_level))
    logger.debug(f"Verbosity is {verbose}")
    logger.debug(f"Logging set to {logging_level}")

    evaluation_packages = get_last_evaluation(CHANNELS[channel]["packages"])
    evaluation_options = get_last_evaluation(CHANNELS[channel]["options"])
    evaluation_packages_builds = get_evaluation_builds(evaluation_packages["id"])

    es = elasticsearch.Elasticsearch([es_url])

    alias_name, index_name = create_index_name(
        channel, evaluation_packages, evaluation_options
    )
    index_created = ensure_index(es, index_name, MAPPING, force)

    if index_created:
        write(
            "packages",
            es,
            index_name,
            *get_packages(evaluation_packages, evaluation_packages_builds),
        )
        write("options", es, index_name, *get_options(evaluation_options))

    update_alias(es, alias_name, index_name)


if __name__ == "__main__":
    run()
