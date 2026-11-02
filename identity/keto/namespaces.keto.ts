import { Namespace, Context } from "@ory/keto-namespace-types";

// ───--- Identities ---───

class User implements Namespace { }

class ServiceAccount implements Namespace { }

// ───--- Groups ---───
class Group implements Namespace {
    related: {
        // Sujetos directos (para includes)
        members_user: (User | ServiceAccount)[]

        // Grupos anidados (para traverse).
        // Tipado como Group[], NO como SubjectSet<Group, "members">[]
        members_group: Group[]
    }

    permits = {
        isMember: (ctx: Context): boolean =>
            this.related.members_user.includes(ctx.subject) ||
            this.related.members_group.traverse((group) => group.permits.isMember(ctx))
    }
}

// ───--- Roles ---───
class Role implements Namespace {
    related: {
        // Sujetos directos
        members_user: (User | ServiceAccount)[]

        // Grupos que aportan miembros al rol
        members_group: Group[]

        members_role: Role[]
    }

    permits = {
        isMember: (ctx: Context): boolean =>
            this.related.members_user.includes(ctx.subject) ||
            this.related.members_group.traverse((group) => group.permits.isMember(ctx))
            ||
            this.related.members_role.traverse((role) => role.permits.isMember(ctx))
    }
}

// ───--- Organizations ---───
class Organization implements Namespace {
    related: {
        "org.view": Role[]
        "org.manage_members": Role[]
        "org.manage_roles": Role[]
        "org.manage_settings": Role[]
        "org.manage_billing": Role[]
        "org.manage_security": Role[]
        "org.audit": Role[]
    }

    permits = {
        view: (ctx: Context): boolean =>
            this.related["org.view"].traverse((role) => role.permits.isMember(ctx)),

        manageMembers: (ctx: Context): boolean =>
            this.related["org.manage_members"].traverse((role) => role.permits.isMember(ctx)),

        manageRoles: (ctx: Context): boolean =>
            this.related["org.manage_roles"].traverse((role) => role.permits.isMember(ctx)),

        manageSettings: (ctx: Context): boolean =>
            this.related["org.manage_settings"].traverse((role) => role.permits.isMember(ctx)),

        manageBilling: (ctx: Context): boolean =>
            this.related["org.manage_billing"].traverse((role) => role.permits.isMember(ctx)),

        manageSecurity: (ctx: Context): boolean =>
            this.related["org.manage_security"].traverse((role) => role.permits.isMember(ctx)),

        audit: (ctx: Context): boolean =>
            this.related["org.audit"].traverse((role) => role.permits.isMember(ctx))
    }
}

// ───--- Apps ---───
class Application implements Namespace {
    related: {
        "app.use": Role[]
        "app.configure": Role[]
        "app.manage_members": Role[]
        "app.audit": Role[]
    }

    permits = {
        use: (ctx: Context): boolean =>
            this.related["app.use"].traverse((role) => role.permits.isMember(ctx)),

        configure: (ctx: Context): boolean =>
            this.related["app.configure"].traverse((role) => role.permits.isMember(ctx)),

        manageMembers: (ctx: Context): boolean =>
            this.related["app.manage_members"].traverse((role) => role.permits.isMember(ctx)),

        audit: (ctx: Context): boolean =>
            this.related["app.audit"].traverse((role) => role.permits.isMember(ctx))
    }
}

// ───--- Workspace ---───
class Workspace implements Namespace {
    related: {
        "workspace.view": Role[]
        "workspace.create_resource": Role[]
        "workspace.manage_members": Role[]
        "workspace.manage_settings": Role[]
    }

    permits = {
        view: (ctx: Context): boolean =>
            this.related["workspace.view"].traverse((role) => role.permits.isMember(ctx)),

        createResource: (ctx: Context): boolean =>
            this.related["workspace.create_resource"].traverse((role) => role.permits.isMember(ctx)),

        manageMembers: (ctx: Context): boolean =>
            this.related["workspace.manage_members"].traverse((role) => role.permits.isMember(ctx)),

        manageSettings: (ctx: Context): boolean =>
            this.related["workspace.manage_settings"].traverse((role) => role.permits.isMember(ctx))
    }
}

// ───--- Generic resources ---───
class Resource implements Namespace {
    related: {
        owners_user: (User | ServiceAccount)[]
        owners_group: Group[]
        owners_role: Role[]

        editors_user: (User | ServiceAccount)[]
        editors_group: Group[]
        editors_role: Role[]

        viewers_user: (User | ServiceAccount)[]
        viewers_group: Group[]
        viewers_role: Role[]

        // Herencia desde recursos padre
        parents: Resource[]
    }

    permits = {
        isOwner: (ctx: Context): boolean => 
            this.related.owners_user.includes(ctx.subject) ||
            this.related.owners_group.traverse((g) => g.permits.isMember(ctx)) ||
            this.related.owners_role.traverse((r) => r.permits.isMember(ctx))
        read: (ctx: Context): boolean =>
            // Owners
            this.permits.isOwner(ctx) ||
            // Editors
            this.related.editors_user.includes(ctx.subject) ||
            this.related.editors_group.traverse((g) => g.permits.isMember(ctx)) ||
            this.related.editors_role.traverse((r) => r.permits.isMember(ctx)) ||
            // Viewers
            this.related.viewers_user.includes(ctx.subject) ||
            this.related.viewers_group.traverse((g) => g.permits.isMember(ctx)) ||
            this.related.viewers_role.traverse((r) => r.permits.isMember(ctx)) ||
            // Herencia
            this.related.parents.traverse((parent) => parent.permits.read(ctx)),

        update: (ctx: Context): boolean =>
            this.permits.isOwner(ctx) ||
            this.related.editors_user.includes(ctx.subject) ||
            this.related.editors_group.traverse((g) => g.permits.isMember(ctx)) ||
            this.related.editors_role.traverse((r) => r.permits.isMember(ctx)) ||
            this.related.parents.traverse((parent) => parent.permits.update(ctx)),

        share: (ctx: Context): boolean =>
            this.permits.isOwner(ctx),

        delete: (ctx: Context): boolean =>
            this.permits.isOwner(ctx),

        manage: (ctx: Context): boolean =>
            this.permits.isOwner(ctx)
    }
}