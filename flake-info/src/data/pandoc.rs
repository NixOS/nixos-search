use std::path::PathBuf;

use lazy_static::lazy_static;
use log::debug;
use pandoc::{
    InputFormat, InputKind, OutputFormat, OutputKind, PandocError, PandocOption, PandocOutput,
};

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
        if !self.as_ref().contains("</") {
            return Ok(self.as_ref().to_owned());
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
        ]);

        pandoc.execute().map(|result| match result {
            PandocOutput::ToBuffer(description) => description,
            _ => unreachable!(),
        })
    }
}
