from rest_framework.exceptions import PermissionDenied


class GenericPermsViewMixin:
    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)

        user = getattr(request, "user", None)
        if user and user.is_authenticated and getattr(user, "is_installer_user", False):
            raise PermissionDenied()
