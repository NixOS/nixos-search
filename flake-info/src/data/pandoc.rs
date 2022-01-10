use std::fs::File;
use std::io::Write;
use std::path::PathBuf;

use lazy_static::lazy_static;
use log::debug;
use pandoc::{
    InputFormat, InputKind, OutputFormat, OutputKind, PandocError, PandocOption, PandocOutput,
};

const XREF_FILTER: &str = include_str!("fix-xrefs.lua");

lazy_static! {
    static ref FILTERS_PATH: PathBuf = std::env::var("NIXPKGS_PANDOC_FILTERS_PATH")
        .unwrap_or("".into())
        .into();
}

pub trait PandocExt {
    fn render(&self) -> Result<String, PandocError>;
}

impl<T: AsRef<str>> PandocExt for T {
    fn render(&self) -> Result<String, PandocError> {
        if !self.as_ref().contains("<") {
            return Ok(format!(
                "<rendered-docbook>{}</rendered-docbook>",
                self.as_ref()
            ));
        }

        let citeref_filter = {
            let mut p = FILTERS_PATH.clone();
            p.push("docbook-reader/citerefentry-to-rst-role.lua");
            p
        };
        let man_filter = {
            let mut p = FILTERS_PATH.clone();
            p.push("link-unix-man-references.lua");
            p
        };
        let tmpdir = tempfile::tempdir()?;
        let xref_filter = tmpdir.path().join("fix-xrefs.lua");
        writeln!(File::create(&xref_filter)?, "{}", XREF_FILTER)?;

        let mut pandoc = pandoc::new();
        let wrapper_xml = format!(
            "
                <xml xmlns:xlink=\"http://www.w3.org/1999/xlink\">
                <para>{}</para>
                </xml>
                ",
            self.as_ref()
        );

        pandoc.set_input(InputKind::Pipe(wrapper_xml));
        pandoc.set_input_format(InputFormat::DocBook, Vec::new());
        pandoc.set_output(OutputKind::Pipe);
        pandoc.set_output_format(OutputFormat::Html, Vec::new());
        pandoc.add_options(&[
            PandocOption::LuaFilter(citeref_filter),
            PandocOption::LuaFilter(man_filter),
            PandocOption::LuaFilter(xref_filter),
        ]);

        pandoc.execute().map(|result| match result {
            PandocOutput::ToBuffer(description) => {
                format!("<rendered-docbook>{}</rendered-docbook>", description)
            }
            _ => unreachable!(),
        })
    }
}
