import { createSignal } from 'solid-js'
import { useNavigate } from '@solidjs/router'
import { register } from '../lib/api'

export default function Register() {
  const navigate = useNavigate()
  const [username, setUsername] = createSignal('')
  const [password, setPassword] = createSignal('')
  const [confirmPassword, setConfirmPassword] = createSignal('')
  const [error, setError] = createSignal('')
  const [loading, setLoading] = createSignal(false)

  async function onSubmit(e) {
    e.preventDefault()
    setError('')

    if (username().trim().length < 3) {
      setError('Brugernavn skal være mindst 3 tegn')
      return
    }

    if (password().length < 8) {
      setError('Adgangskode skal være mindst 8 tegn')
      return
    }

    if (password() !== confirmPassword()) {
      setError('Adgangskoderne er ikke ens')
      return
    }

    setLoading(true)
    try {
      await register(username().trim(), password())
      navigate('/', { replace: true })
    } catch (err) {
      setError(err.message || 'Registrering mislykkedes')
    } finally {
      setLoading(false)
    }
  }

  return (
    <main class="page page--narrow">
      <div class="card">
        <h1 class="app-title">Vejledningskø</h1>
        <p class="lede">Opret en lærerkonto.</p>
        <form class="form" onSubmit={onSubmit}>
          <label class="field">
            <span class="field-label">Brugernavn</span>
            <input
              class="input"
              name="username"
              autocomplete="username"
              value={username()}
              onInput={(e) => setUsername(e.currentTarget.value)}
              required
              minLength={3}
            />
          </label>
          <label class="field">
            <span class="field-label">Adgangskode</span>
            <input
              class="input"
              type="password"
              name="password"
              autocomplete="new-password"
              value={password()}
              onInput={(e) => setPassword(e.currentTarget.value)}
              required
              minLength={8}
            />
          </label>
          <label class="field">
            <span class="field-label">Bekræft adgangskode</span>
            <input
              class="input"
              type="password"
              name="confirmPassword"
              autocomplete="new-password"
              value={confirmPassword()}
              onInput={(e) => setConfirmPassword(e.currentTarget.value)}
              required
              minLength={8}
            />
          </label>
          {error() && <p class="form-error">{error()}</p>}
          <button class="btn btn-primary" type="submit" disabled={loading()}>
            {loading() ? 'Opretter…' : 'Opret konto'}
          </button>
        </form>
      </div>
    </main>
  )
}