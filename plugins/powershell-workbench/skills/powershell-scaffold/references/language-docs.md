# Shared language documentation workflow

Keep PowerShell, DISM, update and Ollama research on the existing authoritative documentation
catalog. New language seeds are canonical in assets/language-documentation-catalog.json at
the plugin root; do not duplicate project topic notes inside the plugin. New seeds do not
refresh the older catalog's verifiedAtUtc timestamp.

Identify language/runtime version, host application, platform and intended operation. Open
relevant primary specifications or product docs before technical claims. Record exact URL,
check date, applicability, documented behavior, observation, inference, test evidence and
limitations. A source seed or opened index is not verification of all linked topics.

Separate XML well-formedness, namespaces, XSD and application behavior; C# XML-doc comments
are a different topic. Batch and interactive CMD share cmd.exe but percent variables,
expansion and quoting differ by context. Never use cmd /c to syntax-test arbitrary source.
For Lua distinguish 5.1-5.4, LuaJIT and embedded game APIs; Lua 5.4 parser success does not
prove WoW runtime compatibility. For JavaScript distinguish ESM/CommonJS and browser/Node.
For SQL identify the vendor before using the T-SQL seed. HTML/CSS parse acceptance is not
browser rendering verification. YAML custom constructors can execute code: do not use unsafe loaders.

Documentation records link to component UUID/version/hash. Language coverage is extensible;
new languages need a docs entry, adapter ID, non-executing parser contract, fixtures, runtime
version policy and validated behavior before their checkpoint can pass. Follow the current
Windows DISM Update Docs execution/research distinction for servicing questions without
copying its machine-specific library location.
