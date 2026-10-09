// Shared by persisted report cards and the extraction preview. Unknown never looks normal.
window.VanguardObservations = {
  labels: { breathing: 'Breathing', consciousness: 'Consciousness', severeBleeding: 'Severe Bleeding', walking: 'Walking', circulation: 'Circulation' },
  status(key, value) {
    const statuses = {
      breathing: { normal: 'Reported normal', abnormal: 'Difficulty breathing', absent: 'Not breathing' },
      consciousness: { alert: 'Responsive', confused: 'Confused / altered', unresponsive: 'Unresponsive' },
      severeBleeding: { present: 'Severe bleeding reported', absent: 'No severe bleeding reported', uncertain: 'Severity uncertain' },
      walking: { able: 'Independent', unable: 'Unable', assisted: 'With assistance' },
      circulation: { present: 'Radial pulse palpable', absent: 'Radial pulse not palpable', uncertain: 'Uncertain' },
    };
    return statuses[key]?.[value] || 'Unknown / unassessed';
  },
  render(observations = {}) {
    const section = document.createElement('section'); section.className = 'rnote triage-observations';
    const title = document.createElement('h3'); title.textContent = 'Triage observations · unverified'; section.append(title);
    for (const [key, label] of Object.entries(this.labels)) {
      const row = document.createElement('p'); row.dataset.observation = key;
      row.textContent = `${label}: ${this.status(key, observations?.[key])}`; section.append(row);
    }
    return section;
  },
};
