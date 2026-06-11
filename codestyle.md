Do not add single helper functions if the function is only used a single place or the inner logic is so small that the helper function adds no meaningful clarity.
Generally, indirection should be considered as it can cost understanding.

Try to follow the style of the file you are editing. Use fully qualified names, except when shorthand is obvious like AST.

Look at the rest of the code to see if there are patterns that you can reuse or if you can extract functionallity from existing functions to reuse.