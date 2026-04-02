# Contribution

- Determine scope of change High(feature level) or Low(bug fix, etc.)
- Make change to functionality and documentation (documenting depends on scope, see description below)
- Make a pull request with description
    - Keep pull requests focused to one use-case, don't combine multiple use-cases into one pull request

> In case Pull Requests are not merged your contribution still can be made into a custom plugin with add/remove functionality

Notes:
- at current `vertical slice experimental` stage solid foundation and vertical slice features are more welcome than horizontal slice features, because if a vertical slice feature gets changed whole horizontal slice layer needs to be updated or removed
- when planning or developing feature please keep in mind **Goals** and **Key Ideas** from [Readme](../README.md)
- see [Style Guide](StyleGuide.md)

### Dos and Don'ts:
Do:
- it's ok to have non-generic functionality in generated code when needed

Don't:
- non-generic functionality in main code
- non-generic functionality in generated code where generic is approximately same performance and functionality

# Program Development via Documentation

In any project Features **functionality exists in two states** Actual and Intended(same as Expected).</br>Additional requirement is to have **one source of truth** for functionality.

Actual functionality is present in form of code and tends towards Intended.
</br>Intended functionality can exist in different places(code, doc, brain), to make it usable it should be formalized into descritpion.
</br>Description of Intended functionality always should be in one place — documentation(but place of doc can vary see further explanation)


>Program Development is describing new Intended functionality and changing actual functionality to match intended

>Documentation is description of Intended functionality

Often documentation becomes stale and solution to this is no-doc or self-documenting code. In this case Actual code becomes its own documentation and is already considered as Expected, users should read it to understand it.

## MoonHug Editor Documentation
MoonHug Editor documentation is presented by:

- High level — manual description of UX Feature
- Low level — self-documenting code, comments and unit-tests

### High Level Scope - UX Feature
High level building block of Editor is UX Feature(or just Feature in short) — what gives impact to the user.

#### Feature Qualities(in ideal case):
- Easy to install
    - preinstalled - may have optional on/off toggle in settings
    - plugin - has add/remove functionality (unique features not fitting main Editor)

- Easy to use
    - documented - at least high level explanation and usage.
    - break proof - unit tests for key functionality(allows safe refactoring)
    - optional extensibility - extending functionality without feature modification

### Low Level Scope - functionalities
On lower level Feature consists of smaller building blocks — use-cases or functionalities.

> When making changes to code its good to understand scope level and type of actions applied

#### Possible actions on functionality or its description:
- Add - new functionality without changing existing
- Modify - changing existing functionality to do something else
- Remove - remove unused or unneeded functionality
- Fix - fixing error in existing functionality (changing actual to intended)
- Refactor - changing code without changing its key functionality

