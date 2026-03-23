import { createSignal, onMount } from 'solid-js'
import { useNavigate } from '@solidjs/router'
import { login, listQueues } from '../lib/api'

export default function Login() {
  const navigate = useNavigate()
  const [username, setUsername] = createSignal('')
  const [password, setPassword] = createSignal('')
  const [error, setError] = createSignal('')
  const [loading, setLoading] = createSignal(false)
  const [checking, setChecking] = createSignal(true)

  onMount(async () => {
    try {
      await listQueues()
      navigate('/queues', { replace: true })
    } catch (e) {
      if (e.status !== 401) {
        setError('Kunne ikke kontakte serveren. Tjek at API kører.')
      }
    } finally {
      setChecking(false)
    }
  })

  async function onSubmit(e) {
    e.preventDefault()
    setError('')
    setLoading(true)
    try {
      await login(username().trim(), password())
      navigate('/queues', { replace: true })
    } catch (err) {
      setError(err.message || 'Login mislykkedes')
    } finally {
      setLoading(false)
    }
  }

  return (
    <main class="page page--narrow">
      <div class="card card--hero">
        <h1 class="app-title">Vejledningskø</h1>
        <p class="lede">Log ind som lærer for at administrere dine køer.</p>
        {checking() ? (
          <p class="muted">Tjekker session…</p>
        ) : (
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
                autocomplete="current-password"
                value={password()}
                onInput={(e) => setPassword(e.currentTarget.value)}
                required
                minLength={8}
              />
            </label>
            {error() && <p class="form-error">{error()}</p>}
            <button class="btn btn-primary" type="submit" disabled={loading()}>
              {loading() ? 'Logger ind…' : 'Log ind'}
            </button>
          </form>
        )}
      </div>
    </main>
  )
}
