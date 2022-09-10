use lazy_static::lazy_static;
use std::path::{Path, PathBuf};

use pandoc::{
    InputFormat, InputKind, OutputFormat, OutputKind, PandocError, PandocOption, PandocOutput,
};

const FILTERS_PATH: &str = env!("NIXPKGS_PANDOC_FILTERS_PATH");

lazy_static! {
    static ref DOCBOOK_ROLES_FILTER: PathBuf =
        Path::new(FILTERS_PATH).join("docbook-reader/citerefentry-to-rst-role.lua");
    static ref MARKDOWN_ROLES_FILTER: PathBuf =
        Path::new(FILTERS_PATH).join("myst-reader/roles.lua");
    static ref MANPAGE_LINK_FILTER: PathBuf =
        Path::new(FILTERS_PATH).join("link-unix-man-references.lua");
    static ref XREF_FILTER: PathBuf = crate::DATADIR.join("data/fix-xrefs.lua");
}

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
            PandocOption::LuaFilter(DOCBOOK_ROLES_FILTER.clone()),
            PandocOption::LuaFilter(MANPAGE_LINK_FILTER.clone()),
            PandocOption::LuaFilter(XREF_FILTER.clone()),
        ]);

        pandoc.execute().map(|result| match result {
            PandocOutput::ToBuffer(html) => {
                format!("<rendered-html>{}</rendered-html>", html)
            }
            _ => unreachable!(),
        })
    }

    fn render_markdown(&self) -> Result<String, PandocError> {
        let mut pandoc = pandoc::new();
        pandoc.set_input(InputKind::Pipe(self.as_ref().into()));
        pandoc.set_input_format(InputFormat::Markdown, Vec::new());
        pandoc.set_output(OutputKind::Pipe);
        pandoc.set_output_format(OutputFormat::Html, Vec::new());
        pandoc.add_options(&[
            PandocOption::LuaFilter(MARKDOWN_ROLES_FILTER.clone()),
            PandocOption::LuaFilter(MANPAGE_LINK_FILTER.clone()),
            PandocOption::LuaFilter(XREF_FILTER.clone()),
        ]);

        pandoc.execute().map(|result| match result {
            PandocOutput::ToBuffer(html) => {
                format!("<rendered-html>{}</rendered-html>", html)
            }
            _ => unreachable!(),
        })
    }
}
