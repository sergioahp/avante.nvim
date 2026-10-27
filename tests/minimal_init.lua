local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:append(root .. "/target/tests/deps/plenary.nvim")
vim.opt.runtimepath:append(root .. "/target/tests/deps/nui.nvim")
