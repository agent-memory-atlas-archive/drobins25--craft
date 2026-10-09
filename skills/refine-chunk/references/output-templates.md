# Refinement Output Templates

Report formats for refinement outcomes. The orchestrator parses these to track fix patterns.

---

## Simple Fix
```markdown
## Fix Applied

**Error:** Property 'onSubmit' is missing
**File:** `LoginForm.tsx:42`

**Change:**
```diff
- <Form>
+ <Form onSubmit={handleSubmit}>
```

>>> HAND BACK TO validate-chunk: Refinement complete. Re-validate this chunk now.
```

---

## Multiple Fixes
```markdown
## Fixes Applied

### Fix 1: Missing prop
**File:** `LoginForm.tsx:42`
Added onSubmit to Form component

### Fix 2: Unused import
**File:** `LoginForm.tsx:3`
Removed unused useState import

### Fix 3: Missing dependency
**File:** `LoginForm.tsx:28`
Added 'email' to useEffect dependencies

---

>>> HAND BACK TO validate-chunk: Refinement complete. Re-validate this chunk now.
```

---

## Complex Fix (Needs Review)
```markdown
## Fix Required — Review Needed

**Error:** Type 'User | null' is not assignable to type 'User'

**Analysis:**
The `useUser` hook can return null (user not logged in), but
the component assumes user is always present.

**Options:**

1. **Add null check** (safest)
   ```typescript
   if (!user) return <LoginPrompt />
   ```

2. **Assert non-null** (if we know user exists)
   ```typescript
   const user = useUser()!
   ```

3. **Optional chaining** (partial fix)
   ```typescript
   {user?.name}
   ```

My recommendation: **Option 1** — add proper null check with redirect.

Which approach?
- Option 1 (recommended)
- Option 2
- Option 3
- Let me think about it
```
