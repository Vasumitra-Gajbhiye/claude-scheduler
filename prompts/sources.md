# Sources per section

Edit freely. Each section says how many items to include, the time window, where to look,
and whether to use Chrome (the logged-in browser) or WebSearch/WebFetch.
Browsing in Chrome is slow and token-heavy, so use it only where marked.

## day: 📆 TODAY (1–3 entries, today's date only)
- What is significant about today's date: national or international days (e.g. Gandhi Jayanti, Earth Day,
  National Mathematics Day), notable anniversaries and birthdays of major figures, and Indian festivals or observances falling today.
- Tool: WebSearch/WebFetch. Verify the date matches TODAY exactly. Skip trivia like "National Donut Day" unless it's genuinely known.
- Format each entry as: number, name of the day or event, then one line on why it matters. Add a URL line only if you opened a good source.
- If nothing notable falls today, write only the heading and "Nothing notable today.".

## india: 🇮🇳 INDIA (exactly the top 5 stories, last 24 hours)
- Source: The Hindu, read in Chrome (I'm logged in there):
  - https://www.thehindu.com/ (front page)
  - https://www.thehindu.com/news/national/ (National section)
- Tool: Chrome.
- Only genuinely major national stories: politics, policy, economy, courts, major incidents, education and exams.
- Karnataka or Bangalore stories only if they're big.
- Skip opinion pieces, sport, entertainment and minor regional crime.
- Send only the 5 most important stories. Rank by national significance, not recency.
- Fallback, only if The Hindu can't be read in Chrome: thehindu.com blocks WebFetch, so instead WebFetch
  https://indianexpress.com/section/india/ and https://www.livemint.com/news/india, plus WebSearch for today's major India news.
  Say in notes.txt that you used the fallback.

## world: 🌍 WORLD (exactly the top 3 stories, last 24 hours)
- The 3 most important global stories: geopolitics, wars and diplomacy, global economy and markets, major disasters, big elections.
- Sources:
  - Al Jazeera, read with WebFetch: https://www.aljazeera.com/news/ (main source; it reads reliably)
  - WebSearch for today's biggest world stories, to cross-check what matters most globally.
  - The Hindu International: https://www.thehindu.com/news/international/ , but ONLY if Chrome is enabled in this run; otherwise skip it silently.
- Tool: WebFetch/WebSearch. BBC, AP, Reuters, The Guardian and NPR block WebFetch: don't try them.
- Only a failure of Al Jazeera goes in notes.txt; skipping the optional sources is not a failure.
- Don't repeat stories already in the India section.

## tech: 💻 TECH & AI (exactly the top 3 stories, last 24 hours)
- Sources:
  - Hacker News front page: https://news.ycombinator.com/
  - TechCrunch: https://techcrunch.com/
  - The Verge: https://www.theverge.com/
  - Official blogs:
    - Anthropic: https://www.anthropic.com/news
    - OpenAI: https://openai.com/news/
    - Google DeepMind: https://deepmind.google/discover/blog/
    - Meta AI: https://ai.meta.com/blog/
  - Indian tech:
    - Inc42: https://inc42.com/
    - Entrackr: https://entrackr.com/
    - MediaNama: https://www.medianama.com/
- Tool: WebSearch/WebFetch. Do NOT use Chrome for this section.
- Only the 3 most important AI/tech stories of the day: major model or product launches, big funding or acquisitions, AI policy.
- Prefer AI news. Rank by real-world impact.
- No rumours, no fluff, no "10 best" lists.

## events: 📅 EVENTS & COMPETITIONS (up to 8 NEW items, next 90 days)
Events, meetups, talks, hackathons, coding contests, case competitions and challenges, all in one list.
- Where they happen (HARD RULE):
  - Online: any day is fine.
  - Offline: ONLY in Bangalore, and ONLY on a Friday, Saturday or Sunday. Drop offline weekday events and anything in another city.
- When: the event date or the registration deadline must fall within the "next 90 days" window given under # Today. Deadlines must not be past.
- Sources:
  - Luma, read in Chrome (the pages are JS-heavy). Scroll or use the date list to see the coming weeks, not just today:
    - https://luma.com/bangalore
    - https://luma.com/ai and https://luma.com/tech (keep Bangalore or online ones)
  - Unstop (hackathons, case competitions, coding challenges): https://unstop.com/hackathons and https://unstop.com/competitions (read in Chrome when Chrome is enabled; WebFetch gets a cookie wall)
  - Devfolio, WebFetch: https://devfolio.co/hackathons
  - Devpost, WebFetch this JSON listing (the normal page blocks WebFetch): https://devpost.com/api/hackathons?status[]=upcoming&status[]=open
  - Kaggle (new competitions): https://www.kaggle.com/competitions needs JavaScript, so read it in Chrome when Chrome is enabled; otherwise WebSearch for new Kaggle competitions.
  - MLH, WebFetch: https://mlh.io/seasons/2027/events (or the current season; online ones count)
  - Notable company-run ones, e.g. Flipkart GRiD, Amazon ML Challenge, Google/Microsoft student challenges, Smart India Hackathon (find them with WebSearch).
- Keep things worth my time: AI/ML, dev, startup/founder events, hackathons, coding and case competitions, talks by strong people or companies. Must be open to undergrads.
- Skip generic mixers and low-value paid workshops.
- Never list anything already in seen.tsv: reminders about earlier items are sent automatically.
- Order the list by date, soonest first.
- Check every source above, one by one, before deciding there is nothing new.
- Luma's city page only shows the first batch of upcoming events (often just today). To find Bangalore events later in the coming weeks, also WebSearch for things like "luma bangalore AI meetup", "lu.ma bengaluru hackathon <month>", "Bangalore tech events this weekend", and open the luma.com event pages you find. A partial Luma view is not a failure: don't put it in notes.txt. Aim for 4–8 new items; "Nothing notable" is only right if every source was checked and nothing new qualified.

## internships: 💼 INTERNSHIPS (up to 7, stipend ₹50,000/month or more)
- HARD RULE: include only internships paying at least ₹50,000 per month (or the equivalent: ₹1.5L+ for a 3-month total, or USD/EUR equivalent).
  - The stipend must be stated on the page, OR the role is a well-known big-firm programme that is publicly known to pay above this
    (e.g. Google, Microsoft, Goldman Sachs, JPMorgan, Amazon, quant firms). For these, write "Stipend: not stated, typically ₹1L+/month".
  - Drop anything below ₹50,000/month, unpaid, or with an unknown stipend at a small or unknown company.
- Sources:
  - Unstop internships: https://unstop.com/internships
  - Internshala (tech and data roles): https://internshala.com/internships/computer-science-internship/ and https://internshala.com/internships/data-science-internship/
  - Wellfound: https://wellfound.com/jobs
  - WebSearch for newly announced 2027 internship or early-careers programmes at big firms in India or remote (JPMorgan, Goldman Sachs, Google, Microsoft, Amazon, etc.).
- Tool: WebSearch/WebFetch first. Use Chrome for Unstop only if WebFetch can't read it.
- NEVER use LinkedIn.
- Give every item an eligibility note for a first-year undergrad:
  - "✅ open to 1st years", or
  - "🕓 2nd/3rd-year only: note for the cycle".
- Still include big-name programmes I'm not eligible for yet, but mark them.
