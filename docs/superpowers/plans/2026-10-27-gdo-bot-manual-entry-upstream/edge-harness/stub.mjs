export function createClient() { return globalThis.__sb }
export const slackHeader = (t) => ({ type: 'header', text: t })
export const slackSections = (b) => [{ type: 'section', text: b }]
export const slackIdentity = async () => ({ username: 'DERM Tracker' })
