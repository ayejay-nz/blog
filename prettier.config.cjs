/** @type {import('prettier').Config} */
module.exports = {
    printWidth: 100,
    tabWidth: 4,
    useTabs: false,
    semi: true,
    singleQuote: true,
    trailingComma: 'all',
    bracketSpacing: true, // { foo: 1 }
    arrowParens: 'always', // (req, res) => {}
    endOfLine: 'lf',

    overrides: [
        {
            files: ['*.json', '*.yml'],
            options: { printWidth: 80 },
        },
    ],
};
