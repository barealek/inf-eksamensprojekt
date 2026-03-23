import { Router, Route } from '@solidjs/router'
import Login from './pages/Login'
import QueueList from './pages/QueueList'
import QueueDetail from './pages/QueueDetail'
import Wait from './pages/Wait'

export default function App() {
  return (
    <div class="app-shell">
      <Router>
        <Route path="/" component={Login} />
        <Route path="/queues" component={QueueList} />
        <Route path="/queue/:id" component={QueueDetail} />
        <Route path="/wait/:id" component={Wait} />
      </Router>
    </div>
  )
}
