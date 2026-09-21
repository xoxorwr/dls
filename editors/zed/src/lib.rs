use zed_extension_api::{self as zed, CodeLabel, CodeLabelSpan, LanguageServerId, Result};

struct DExtension {
    cached_binary_path: Option<String>,
}

impl DExtension {
    fn language_server_binary_path(
        &mut self,
        worktree: &zed::Worktree,
    ) -> Result<String> {
        if let Some(path) = &self.cached_binary_path {
            return Ok(path.clone());
        }

        if let Some(path) = worktree.which("dls") {
            self.cached_binary_path = Some(path.clone());
            return Ok(path);
        }

        Err("dls binary not found in PATH".into())
    }
}

impl zed::Extension for DExtension {
    fn new() -> Self {
        Self {
            cached_binary_path: None,
        }
    }

    fn language_server_command(
        &mut self,
        _language_server_id: &LanguageServerId,
        worktree: &zed::Worktree,
    ) -> Result<zed::Command> {
        Ok(zed::Command {
            command: self.language_server_binary_path(worktree)?,
            args: vec![],
            env: Default::default(),
        })
    }

    fn label_for_completion(
        &self,
        _language_server_id: &LanguageServerId,
        completion: zed::lsp::Completion,
    ) -> Option<CodeLabel> {
        let label_detail = match &completion.label_details {
            Some(label_detail) => match &label_detail.detail {
                Some(detail) => detail.trim(),
                None => "",
            },
            None => "",
        };

        let label_desc = match &completion.label_details {
            Some(label_detail) => match &label_detail.description {
                Some(description) => description.trim(),
                None => "",
            },
            None => "",
        };

        let label = completion
            .label
            .strip_prefix('•')
            .unwrap_or(&completion.label)
            .trim()
            .to_owned()
            + label_detail;

        Some(CodeLabel {
            code: label.to_string() + " -> " + label_desc,
            spans: vec![CodeLabelSpan::code_range(
                0..label.len() + 4 + label_desc.len(),
            )],
            filter_range: (0..label.len()).into(),
        })
    }
}

zed::register_extension!(DExtension);
