vim.opt.runtimepath:prepend(vim.fn.getcwd())
-- plenary must be on runtimepath; adjust path to your plenary install
vim.opt.runtimepath:prepend(vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"))
