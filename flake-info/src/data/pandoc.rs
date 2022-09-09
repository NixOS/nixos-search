use std::fs::File;
use std::io::Write;
use std::path::Path;

use pandoc::{
    InputFormat, InputKind, OutputFormat, OutputKind, PandocError, PandocOption, PandocOutput,
};

const XREF_FILTER: &str = include_str!("fix-xrefs.lua");

const FILTERS_PATH: &str = env!("NIXPKGS_PANDOC_FILTERS_PATH");

pub trait PandocExt {
    fn render_docbook(&self) -> Result<String, PandocError>;
    fn render_markdown(&self) -> Result<String, PandocError>;
}

impl<T: AsRef<str>> PandocExt for T {
    fn render_docbook(&self) -> Result<String, PandocError> {
        if !self.as_ref().contains("<") {
            return Ok(format!(
                "<rendered-html><p>{}</p></rendered-html>",
                self.as_ref()
            ));
        }

        let citeref_filter =
            Path::new(FILTERS_PATH).join("docbook-reader/citerefentry-to-rst-role.lua");
        let man_filter = Path::new(FILTERS_PATH).join("link-unix-man-references.lua");
        let tmpdir = tempfile::tempdir()?;
        let xref_filter = tmpdir.path().join("fix-xrefs.lua");
        writeln!(File::create(&xref_filter)?, "{}", XREF_FILTER)?;

        let wrapper_xml = format!(
            "
                <xml xmlns:xlink=\"http://www.w3.org/1999/xlink\">
                <para>{}</para>
                </xml>
                ",
            self.as_ref()
        );

        let mut pandoc = pandoc::new();
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
            PandocOutput::ToBuffer(html) => {
                format!("<rendered-html>{}</rendered-html>", html)
            }
            _ => unreachable!(),
        })
    }

    fn render_markdown(&self) -> Result<String, PandocError> {
        let roles_filter = Path::new(FILTERS_PATH).join("myst-reader/roles.lua");
        let man_filter = Path::new(FILTERS_PATH).join("link-unix-man-references.lua");
        let tmpdir = tempfile::tempdir()?;
        let xref_filter = tmpdir.path().join("fix-xrefs.lua");
        writeln!(File::create(&xref_filter)?, "{}", XREF_FILTER)?;

        let mut pandoc = pandoc::new();
        pandoc.set_input(InputKind::Pipe(self.as_ref().into()));
        pandoc.set_input_format(InputFormat::Markdown, Vec::new());
        pandoc.set_output(OutputKind::Pipe);
        pandoc.set_output_format(OutputFormat::Html, Vec::new());
        pandoc.add_options(&[
            PandocOption::LuaFilter(roles_filter),
            PandocOption::LuaFilter(man_filter),
            PandocOption::LuaFilter(xref_filter),
        ]);

        pandoc.execute().map(|result| match result {
            PandocOutput::ToBuffer(html) => {
                format!("<rendered-html>{}</rendered-html>", html)
            }
            _ => unreachable!(),
        })
    }
}
